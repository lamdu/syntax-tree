-- | Alpha-equality for schemes
{-# LANGUAGE NoImplicitPrelude, TypeOperators, FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
module AST.Term.Scheme.AlphaEq
    ( alphaEq
    ) where

import           AST
import           AST.Class.Combinators (And)
import           AST.Class.HasChild (HasChild(..))
import           AST.Class.ZipMatch (zipMatchWith_)
import           AST.Term.Scheme (Scheme, schemeToRestrictedType)
import           AST.Unify (Unify(..), UVarOf, QVarHasInstance, BindingDict(..), UnifyError(..))
import           AST.Unify.Term (UTerm(..), uBody)
import           Control.Lens.Operators
import           Data.Constraint (withDict)
import           Data.Maybe (fromMaybe)
import           Data.Proxy (Proxy(..))

import           Prelude.Compat

goUTerm ::
    forall m t.
    Recursive (Unify m) t =>
    Tree (UVarOf m) t -> Tree (UTerm (UVarOf m)) t ->
    Tree (UVarOf m) t -> Tree (UTerm (UVarOf m)) t ->
    m ()
goUTerm xv USkolem{} yv USkolem{} =
    do
        bindVar binding xv (UInstantiated yv)
        bindVar binding yv (UInstantiated xv)
goUTerm xv (UInstantiated xt) yv (UInstantiated yt)
    | xv == yt && yv == xt = pure ()
    | otherwise = unifyError (SkolemEscape xv)
goUTerm xv USkolem{} yv UUnbound{} = bindVar binding yv (UToVar xv)
goUTerm xv UUnbound{} yv USkolem{} = bindVar binding xv (UToVar yv)
goUTerm _ (UToVar xv) yv yu =
    do
        xu <- lookupVar binding xv
        goUTerm xv xu yv yu
goUTerm xv xu _ (UToVar yv) =
    do
        yu <- lookupVar binding yv
        goUTerm xv xu yv yu
goUTerm xv USkolem{} yv _ = unifyError (SkolemUnified xv yv)
goUTerm xv _ yv USkolem{} = unifyError (SkolemUnified yv xv)
goUTerm xv UUnbound{} yv yu = goUTerm xv yu yv yu -- Term created in structure mismatch
goUTerm xv xu yv UUnbound{} = goUTerm xv xu yv xu -- Term created in structure mismatch
goUTerm _ (UTerm xt) _ (UTerm yt) =
    withDict (recursive :: RecursiveDict (Unify m) t) $
    zipMatchWith_ (Proxy :: Proxy (Recursive (Unify m))) goUVar (xt ^. uBody) (yt ^. uBody)
    & fromMaybe (structureMismatch (\x y -> x <$ goUVar x y) xt yt)
goUTerm _ _ _ _ = error "unexpected state at alpha-eq"

goUVar ::
    Recursive (Unify m) t =>
    Tree (UVarOf m) t -> Tree (UVarOf m) t -> m ()
goUVar xv yv =
    do
        xu <- lookupVar binding xv
        yu <- lookupVar binding yv
        goUTerm xv xu yv yu

-- Check for alpha equality. Raises a `unifyError` when mismatches.
alphaEq ::
    ( ChildrenWithConstraint varTypes (Unify m)
    , Recursive (Unify m) typ
    , Recursive (Unify m `And` HasChild varTypes `And` QVarHasInstance Ord) typ
    ) =>
    Tree Pure (Scheme varTypes typ) ->
    Tree Pure (Scheme varTypes typ) ->
    m ()
alphaEq s0 s1 =
    do
        t0 <- schemeToRestrictedType s0
        t1 <- schemeToRestrictedType s1
        goUVar t0 t1
