{-# LANGUAGE NoImplicitPrelude, DataKinds, FlexibleContexts, FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses, ConstraintKinds, UndecidableSuperClasses #-}
{-# LANGUAGE UndecidableInstances, TypeOperators, TypeFamilies, RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Combinators for partially applied constraints on knots

module AST.Class.Combinators
    ( And
    , TieHasConstraint
    , ApplyKConstraints
    , KLiftConstraints(..)
    , pureKWith, pureKWith'
    , mapKWith
    , foldMapKWith, foldMapKWith'
    , traverseKWith, traverseKWith'
    , traverseKWith_
    ) where

import AST.Class.Applicative
import AST.Class.HasChildrenTypes
import AST.Class.Foldable
import AST.Class.Functor
import AST.Class.Pointed (KPointed(..))
import AST.Class.Traversable
import AST.Knot
import Control.Lens.Operators
import Data.Constraint (Dict(..), Constraint, withDict)
import Data.Foldable (sequenceA_)
import Data.Kind (Type)
import Data.Proxy (Proxy(..))

import Prelude.Compat

class    (c0 k, c1 k) => And c0 c1 (k :: Knot -> *)
instance (c0 k, c1 k) => And c0 c1 k

class    constraint (Tie outer k) => TieHasConstraint constraint outer k
instance constraint (Tie outer k) => TieHasConstraint constraint outer k

type family ApplyKConstraints cs (k :: Knot -> Type) :: Constraint where
    ApplyKConstraints (c ': cs) k = (c k, ApplyKConstraints cs k)
    ApplyKConstraints '[] k = ()

newtype KDict cs k = MkKDict (Dict (ApplyKConstraints cs (RunKnot k)))

class
    (KApplicative k, HasChildrenTypes k) =>
    KLiftConstraints (cs :: [(Knot -> Type) -> Constraint]) k where
    kLiftConstraint :: Tree k (KDict cs)

instance
    (KApplicative k, HasChildrenTypes k) =>
    KLiftConstraints '[] k where
    {-# INLINE kLiftConstraint #-}
    kLiftConstraint = pureK (MkKDict Dict)

instance
    (KLiftConstraints cs k, KLiftConstraint k c) =>
    KLiftConstraints (c ': cs) k where
    {-# INLINE kLiftConstraint #-}
    kLiftConstraint =
        liftK2
        (\(MkKDict c) (MkKDict cs) -> withDict c (withDict cs (MkKDict Dict)))
        (pureKWithConstraint (Proxy :: Proxy c) (MkKDict Dict) :: Tree k (KDict '[c]))
        (kLiftConstraint :: Tree k (KDict cs))

-- A version of `pureKWith` with an additional proxy argument,
-- used to work around a GHC inferrence bug (https://gitlab.haskell.org/ghc/ghc/issues/9223):
-- For some reason GHC has problem with unifying the `n` type parameter,
-- for example if trying to use the regular `foldMapKWith` in `traverseKWith_`.
{-# INLINE pureKWith' #-}
pureKWith' ::
    forall constraints k n.
    KLiftConstraints constraints k =>
    Proxy n ->
    Proxy constraints ->
    (forall child. ApplyKConstraints constraints child => Tree n child) ->
    Tree k n
pureKWith' _ _ f = mapK (\(MkKDict d) -> withDict d f) (kLiftConstraint :: Tree k (KDict constraints))


{-# INLINE pureKWith #-}
pureKWith ::
    forall constraints k n.
    KLiftConstraints constraints k =>
    Proxy constraints ->
    (forall child. ApplyKConstraints constraints child => Tree n child) ->
    Tree k n
pureKWith = pureKWith' Proxy

{-# INLINE mapKWith #-}
mapKWith ::
    (KFunctor k, KLiftConstraints constraints (ChildrenTypesOf k)) =>
    Proxy constraints ->
    (forall child. ApplyKConstraints constraints child => Tree m child -> Tree n child) ->
    Tree k m ->
    Tree k n
mapKWith p f = mapC (pureKWith p (MkMapK f))

-- A version of `traverseKWith` with an additional proxy argument,
-- see comment for `pureKWith'`.
{-# INLINE foldMapKWith' #-}
foldMapKWith' ::
    (Monoid a, KFoldable k, KLiftConstraints constraints (ChildrenTypesOf k)) =>
    Proxy a ->
    Proxy constraints ->
    (forall child. ApplyKConstraints constraints child => Tree n child -> a) ->
    Tree k n -> a
foldMapKWith' _ p f = foldMapC (pureKWith p (_ConvertK # f))

{-# INLINE foldMapKWith #-}
foldMapKWith ::
    (Monoid a, KFoldable k, KLiftConstraints constraints (ChildrenTypesOf k)) =>
    Proxy constraints ->
    (forall child. ApplyKConstraints constraints child => Tree n child -> a) ->
    Tree k n -> a
foldMapKWith = foldMapKWith' Proxy

-- A version of `traverseKWith` with an additional proxy argument,
-- see comment for `pureKWith'`.
{-# INLINE traverseKWith' #-}
traverseKWith' ::
    (Applicative f, KTraversable k, KLiftConstraints constraints (ChildrenTypesOf k)) =>
    Proxy n ->
    Proxy constraints ->
    (forall c. ApplyKConstraints constraints c => Tree m c -> f (Tree n c)) ->
    Tree k m -> f (Tree k n)
traverseKWith' _ p f = sequenceC . mapC (pureKWith p (MkMapK (MkContainedK . f)))

{-# INLINE traverseKWith #-}
traverseKWith ::
    (Applicative f, KTraversable k, KLiftConstraints constraints (ChildrenTypesOf k)) =>
    Proxy constraints ->
    (forall c. ApplyKConstraints constraints c => Tree m c -> f (Tree n c)) ->
    Tree k m -> f (Tree k n)
traverseKWith = traverseKWith' Proxy

{-# INLINE traverseKWith_ #-}
traverseKWith_ ::
    forall f k constraints m.
    (Applicative f, KFoldable k, KLiftConstraints constraints (ChildrenTypesOf k)) =>
    Proxy constraints ->
    (forall c. ApplyKConstraints constraints c => Tree m c -> f ()) ->
    Tree k m -> f ()
traverseKWith_ p f =
    sequenceA_ . foldMapKWith' (Proxy :: Proxy [f ()]) p ((:[]) . f)
