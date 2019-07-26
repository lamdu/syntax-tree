{-# LANGUAGE NoImplicitPrelude, TemplateHaskell, DeriveGeneric, StandaloneDeriving #-}
{-# LANGUAGE ConstraintKinds, UndecidableInstances, TypeFamilies, ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses, GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators, FlexibleContexts, DataKinds, LambdaCase #-}
{-# LANGUAGE RankNTypes, DerivingStrategies #-}

module AST.Term.Nominal
    ( NominalDecl(..), nParams, nScheme
    , NominalInst(..), nId, nArgs
    , ToNom(..), tnId, tnVal
    , FromNom(..), _FromNom

    , HasNominalInst(..)
    , NomVarTypes
    , MonadNominals(..)
    , LoadedNominalDecl, loadNominalDecl
    , applyNominal
    ) where

import           AST
import           AST.Class (_MapK)
import           AST.Class.HasChild (HasChild(..))
import           AST.Class.Foldable (_ConvertK)
import           AST.Class.Recursive (wrapM)
import           AST.Class.Traversable (ContainedK(..))
import           AST.Class.ZipMatch (ZipMatch(..), Both(..))
import           AST.Combinator.Single (Single)
import           AST.Infer
import           AST.Term.FuncType (HasFuncType(..), FuncType(..))
import           AST.Term.Map (TermMap(..), _TermMap)
import           AST.Term.Scheme
import           AST.Unify
import           AST.Unify.Generalize (GTerm(..), _GMono, instantiateWith, instantiateForAll)
import           AST.Unify.New (newTerm)
import           AST.Unify.QuantifiedVar (HasQuantifiedVar(..), QVarHasInstance)
import           AST.Unify.Term (UTerm(..))
import           Control.Applicative (Alternative(..))
import           Control.DeepSeq (NFData)
import           Control.Lens (Prism', makeLenses, makePrisms)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad.Trans.Writer (execWriterT)
import           Data.Binary (Binary)
import           Data.Constraint (Constraint, Dict(..), withDict)
import           Data.Foldable (traverse_)
import           Data.Functor.Const (Const)
import           Data.Proxy (Proxy(..))
import qualified Data.Map as Map
import           GHC.Generics (Generic)
import           Text.PrettyPrint ((<+>))
import qualified Text.PrettyPrint as Pretty
import           Text.PrettyPrint.HughesPJClass (Pretty(..), maybeParens)

import           Prelude.Compat

type family NomVarTypes (typ :: Knot -> *) :: Knot -> *

-- | A declaration of a nominal type.
data NominalDecl typ k = NominalDecl
    { _nParams :: Tree (NomVarTypes typ) QVars
    , _nScheme :: Scheme (NomVarTypes typ) typ k
    } deriving Generic

-- | An instantiation of a nominal type
data NominalInst nomId varTypes k = NominalInst
    { _nId :: nomId
    , _nArgs :: Tree varTypes (QVarInstances (RunKnot k))
    } deriving Generic

-- | Nominal data constructor.
-- Wraps the content of a nominal with its data constructor.
-- Introduces the nominal's forall type variables into the value's scope.
data ToNom nomId term k = ToNom
    { _tnId :: nomId
    , _tnVal :: Node k term
    } deriving Generic

newtype FromNom nomId (term :: Knot -> *) (k :: Knot) = FromNom nomId
    deriving newtype (Eq, Ord, Binary, NFData)
    deriving stock (Show, Generic)

instance HasNodes (NominalDecl t) where
    type NodeTypesOf (NominalDecl t) = Single t
    type NodesConstraint (NominalDecl t) = KnotsConstraint '[t]

instance HasNodes (ToNom n t) where
    type NodeTypesOf (ToNom n t) = Single t
    type NodesConstraint (ToNom n t) = KnotsConstraint '[t]

instance HasNodes (FromNom n t) where
    type NodeTypesOf (FromNom n t) = Const ()
    type NodesConstraint (FromNom n t) = KnotsConstraint '[]

instance HasNodes v => HasNodes (NominalInst n v) where
    type NodeTypesOf (NominalInst n v) = NodeTypesOf v
    type NodesConstraint (NominalInst n v) = NodesConstraint (NodeTypesOf v)
    {-# INLINE hasNodes #-}
    hasNodes _ = withDict (hasNodes (Proxy :: Proxy v)) Dict

makeLenses ''NominalDecl
makeLenses ''NominalInst
makeLenses ''ToNom
makePrisms ''FromNom
makeKTraversableAndBases ''NominalDecl
makeKTraversableAndBases ''ToNom
makeKTraversableAndBases ''FromNom

instance (KFunctor v, HasNodes v) => KFunctor (NominalInst n v) where
    mapC f (NominalInst n v) =
        withDict (hasNodes (Proxy :: Proxy v)) $
        mapC (mapK (_MapK %~ (_QVarInstances . Lens.mapped %~)) f) v & NominalInst n

instance (KFoldable v, HasNodes v) => KFoldable (NominalInst n v) where
    foldMapC f (NominalInst _ v) =
        withDict (hasNodes (Proxy :: Proxy v)) $
        foldMapC (mapK (_ConvertK %~ \fq -> foldMap fq . (^. _QVarInstances)) f) v

instance (KTraversable v, HasNodes v) => KTraversable (NominalInst n v) where
    sequenceC (NominalInst n v) =
        traverseK (_QVarInstances (traverse runContainedK)) v
        <&> NominalInst n

instance
    ( Eq nomId
    , ZipMatch varTypes
    , KTraversable varTypes
    , KLiftConstraint varTypes ZipMatch
    , KLiftConstraint varTypes (QVarHasInstance Ord)
    ) =>
    ZipMatch (NominalInst nomId varTypes) where

    {-# INLINE zipMatch #-}
    zipMatch (NominalInst xId x) (NominalInst yId y)
        | xId /= yId = Nothing
        | otherwise =
            zipMatch x y
            >>= traverseKWith (Proxy :: Proxy '[ZipMatch, QVarHasInstance Ord])
                (\(Both (QVarInstances c0) (QVarInstances c1)) ->
                    zipMatch (TermMap c0) (TermMap c1)
                    <&> (^. _TermMap)
                    <&> QVarInstances
                )
            <&> NominalInst xId

instance
    ( c (NominalInst nomId varTypes)
    , KTraversable varTypes
    , KLiftConstraint varTypes (Recursive c)
    ) =>
    Recursive c (NominalInst nomId varTypes) where

    {-# INLINE recursive #-}
    recursive =
        withDict (hasNodes (Proxy :: Proxy varTypes))
        Dict

instance DepsT Pretty nomId term k => Pretty (ToNom nomId term k) where
    pPrintPrec lvl p (ToNom nomId term) =
        (pPrint nomId <> Pretty.text "#") <+> pPrintPrec lvl 11 term
        & maybeParens (p > 10)

instance
    ( Pretty nomId
    , KApply varTypes, KFoldable varTypes
    , KLiftConstraint varTypes (QVarHasInstance Pretty)
    , KLiftConstraint varTypes (NodeHasConstraint Pretty k)
    ) =>
    Pretty (NominalInst nomId varTypes k) where

    pPrint (NominalInst n vars) =
        pPrint n <>
        joinArgs
        (foldMapKWith (Proxy :: Proxy [QVarHasInstance Pretty, NodeHasConstraint Pretty k]) mkArgs vars)
        where
            joinArgs [] = mempty
            joinArgs xs =
                Pretty.text "[" <>
                Pretty.sep (Pretty.punctuate (Pretty.text ",") xs)
                <> Pretty.text "]"
            mkArgs (QVarInstances m) =
                Map.toList m <&>
                \(k, v) ->
                (pPrint k <> Pretty.text ":") <+> pPrint v

data LoadedNominalDecl typ v = LoadedNominalDecl
    { _lnParams :: Tree (NomVarTypes typ) (QVarInstances (RunKnot v))
    , _lnForalls :: Tree (NomVarTypes typ) (QVarInstances (RunKnot v))
    , _lnType :: Tree (GTerm (RunKnot v)) typ
    } deriving Generic

{-# INLINE loadBody #-}
loadBody ::
    ( Unify m typ
    , HasChild varTypes typ
    , Ord (QVar typ)
    ) =>
    Tree varTypes (QVarInstances (UVarOf m)) ->
    Tree varTypes (QVarInstances (UVarOf m)) ->
    Tree typ (GTerm (UVarOf m)) ->
    m (Tree (GTerm (UVarOf m)) typ)
loadBody params foralls x =
    case x ^? quantifiedVar >>= get of
    Just r -> GPoly r & pure
    Nothing ->
        case traverseK (^? _GMono) x of
        Just xm -> newTerm xm <&> GMono
        Nothing -> GBody x & pure
    where
        get v =
            params ^? getChild . _QVarInstances . Lens.ix v <|>
            foralls ^? getChild . _QVarInstances . Lens.ix v

{-# INLINE loadNominalDecl #-}
loadNominalDecl ::
    forall m typ.
    ( Monad m
    , KTraversable (NomVarTypes typ)
    , KLiftConstraint (NomVarTypes typ) (Unify m)
    , Recursive (Unify m `And` HasChild (NomVarTypes typ) `And` QVarHasInstance Ord) typ
    ) =>
    Tree Pure (NominalDecl typ) ->
    m (Tree (LoadedNominalDecl typ) (UVarOf m))
loadNominalDecl (MkPure (NominalDecl params (Scheme foralls typ))) =
    do
        paramsL <- traverseKWith (Proxy :: Proxy '[Unify m]) makeQVarInstances params
        forallsL <- traverseKWith (Proxy :: Proxy '[Unify m]) makeQVarInstances foralls
        wrapM (Proxy :: Proxy (Unify m `And` HasChild (NomVarTypes typ) `And` QVarHasInstance Ord))
            (loadBody paramsL forallsL) typ
            <&> LoadedNominalDecl paramsL forallsL

class MonadNominals nomId typ m where
    getNominalDecl :: nomId -> m (Tree (LoadedNominalDecl typ) (UVarOf m))

class HasNominalInst nomId typ where
    nominalInst :: Prism' (Tree typ k) (Tree (NominalInst nomId (NomVarTypes typ)) k)

{-# INLINE lookupParams #-}
lookupParams ::
    forall m varTypes.
    ( Applicative m
    , KTraversable varTypes
    , KLiftConstraint varTypes (Unify m)
    ) =>
    Tree varTypes (QVarInstances (UVarOf m)) ->
    m (Tree varTypes (QVarInstances (UVarOf m)))
lookupParams =
    traverseKWith (Proxy :: Proxy '[Unify m]) ((_QVarInstances . traverse) lookupParam)
    where
        lookupParam v =
            lookupVar binding v
            >>=
            \case
            UInstantiated r -> pure r
            USkolem l ->
                -- This is a phantom-type, wasn't instantiated by `instantiate`.
                scopeConstraints <&> (<> l) >>= newVar binding . UUnbound
            _ -> error "unexpected state at nominal's parameter"

type instance TypeOf  (ToNom nomId expr) = TypeOf expr
type instance ScopeOf (ToNom nomId expr) = ScopeOf expr

instance
    ( Infer m expr
    , MonadScopeLevel m
    , HasNominalInst nomId (TypeOf expr)
    , MonadNominals nomId (TypeOf expr) m
    , KTraversable (NomVarTypes (TypeOf expr))
    , KLiftConstraint (NomVarTypes (TypeOf expr)) (Unify m)
    ) =>
    Infer m (ToNom nomId expr) where

    {-# INLINE inferBody #-}
    inferBody (ToNom nomId val) =
        do
            (valI, paramsT) <-
                do
                    InferredChild valI valT <- inferChild val
                    LoadedNominalDecl params foralls gen <- getNominalDecl nomId
                    recover <-
                        traverseKWith_ (Proxy :: Proxy '[Unify m])
                        (traverse_ (instantiateForAll USkolem) . (^. _QVarInstances))
                        foralls
                        & execWriterT
                    (typ, paramsT) <- instantiateWith (lookupParams params) gen
                    sequence_ recover
                    (valI, paramsT) <$ unify typ valT
                & localLevel
            nominalInst # NominalInst nomId paramsT & newTerm
                <&> InferRes (ToNom nomId valI)

type instance TypeOf  (FromNom nomId expr) = TypeOf expr
type instance ScopeOf (FromNom nomId expr) = ScopeOf expr

instance
    ( Infer m expr
    , HasFuncType (TypeOf expr)
    , HasNominalInst nomId (TypeOf expr)
    , MonadNominals nomId (TypeOf expr) m
    , KTraversable (NomVarTypes (TypeOf expr))
    , KLiftConstraint (NomVarTypes (TypeOf expr)) (Unify m)
    ) =>
    Infer m (FromNom nomId expr) where

    {-# INLINE inferBody #-}
    inferBody (FromNom nomId) =
        do
            LoadedNominalDecl params _ gen <- getNominalDecl nomId
            (typ, paramsT) <- instantiateWith (lookupParams params) gen
            nomT <- nominalInst # NominalInst nomId paramsT & newTerm
            funcType # FuncType nomT typ & newTerm
        <&> InferRes (FromNom nomId)

-- | Get the scheme in a nominal given the parameters of a specific nominal instance.
applyNominal ::
    (Monad m, Recursive (HasChild (NomVarTypes typ) `And` QVarHasInstance Ord `And` constraint) typ) =>
    Proxy constraint ->
    (forall child. constraint child => Tree child k -> m (Tree k child)) ->
    Tree Pure (NominalDecl typ) ->
    Tree (NomVarTypes typ) (QVarInstances k) ->
    m (Tree (Scheme (NomVarTypes typ) typ) k)
applyNominal p mkType (MkPure (NominalDecl _paramsDecl scheme)) params =
    sTyp (subst p mkType params) scheme

subst ::
    forall varTypes typ k constraint m.
    (Monad m, Recursive (HasChild varTypes `And` QVarHasInstance Ord `And` constraint) typ) =>
    Proxy constraint ->
    (forall child. constraint child => Tree child k -> m (Tree k child)) ->
    Tree varTypes (QVarInstances k) -> Tree Pure typ -> m (Tree k typ)
subst p mkType params (MkPure x) =
    case x ^? quantifiedVar of
    Just q ->
        params ^?
        getChild . _QVarInstances . Lens.ix q
        & maybe (mkType (quantifiedVar # q)) pure
    Nothing ->
        withDict (recursive :: (RecursiveDict (HasChild varTypes `And` QVarHasInstance Ord `And` constraint) typ)) $
        traverseKWith (Proxy :: Proxy '[Recursive (HasChild varTypes `And` QVarHasInstance Ord `And` constraint)])
        (subst p mkType params) x
        >>= mkType

type DepsD c t k = ((c (Tree (NomVarTypes t) QVars), c (Node k t)) :: Constraint)
deriving instance DepsD Eq   t k => Eq   (NominalDecl t k)
deriving instance DepsD Ord  t k => Ord  (NominalDecl t k)
deriving instance DepsD Show t k => Show (NominalDecl t k)
instance DepsD Binary t k => Binary (NominalDecl t k)
instance DepsD NFData t k => NFData (NominalDecl t k)

type DepsI c n v k = ((c n, c (Tree v (QVarInstances (RunKnot k)))) :: Constraint)
deriving instance DepsI Eq   n v k => Eq   (NominalInst n v k)
deriving instance DepsI Ord  n v k => Ord  (NominalInst n v k)
deriving instance DepsI Show n v k => Show (NominalInst n v k)
instance DepsI Binary n v k => Binary (NominalInst n v k)
instance DepsI NFData n v k => NFData (NominalInst n v k)

type DepsT c n t k = ((c n, c (Node k t)) :: Constraint)
deriving instance DepsT Eq   n t k => Eq   (ToNom n t k)
deriving instance DepsT Ord  n t k => Ord  (ToNom n t k)
deriving instance DepsT Show n t k => Show (ToNom n t k)
instance DepsT Binary n t k => Binary (ToNom n t k)
instance DepsT NFData n t k => NFData (ToNom n t k)

type DepsL c t k =
    ( ( c (Tree (NomVarTypes t) (QVarInstances (RunKnot k)))
      , c (Tree (GTerm (RunKnot k)) t)
      ) :: Constraint
    )
deriving instance DepsL Eq   t k => Eq   (LoadedNominalDecl t k)
deriving instance DepsL Ord  t k => Ord  (LoadedNominalDecl t k)
deriving instance DepsL Show t k => Show (LoadedNominalDecl t k)
instance DepsL Binary t k => Binary (LoadedNominalDecl t k)
instance DepsL NFData t k => NFData (LoadedNominalDecl t k)
