{-# LANGUAGE NoImplicitPrelude, DataKinds, TypeFamilies, RankNTypes #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, DefaultSignatures, FlexibleContexts #-}
{-# LANGUAGE ConstraintKinds, TypeOperators, ScopedTypeVariables, UndecidableInstances #-}

module AST.Unify.Constraints
    ( TypeConstraints(..)
    , HasTypeConstraints(..)
    , TypeConstraintsAre
    , ScopeConstraintsMonad(..)
    ) where

import Algebra.Lattice (JoinSemiLattice(..))
import Algebra.PartialOrd (PartialOrd(..))
import AST.Class.Children (Children(..), ChildrenWithConstraint)
import AST.Class.Combinators (And)
import AST.Knot (Knot, Tree)
import Data.Proxy (Proxy(..))

import Prelude.Compat

class (PartialOrd c, JoinSemiLattice c) => TypeConstraints c where
    -- | Remove scope constraints
    generalizeConstraints :: c -> c

class
    TypeConstraints (TypeConstraintsOf ast) =>
    HasTypeConstraints (ast :: Knot -> *) where

    type TypeConstraintsOf ast

    applyConstraints ::
        (Applicative m, ChildrenWithConstraint ast constraint) =>
        Proxy constraint ->
        TypeConstraintsOf ast ->
        (TypeConstraintsOf ast -> m ()) ->
        (forall child. constraint child => TypeConstraintsOf child -> Tree p child -> m (Tree q child)) ->
        Tree ast p -> m (Tree ast q)
    default applyConstraints ::
        forall m constraint p q.
        ( ChildrenWithConstraint ast (constraint `And` TypeConstraintsAre (TypeConstraintsOf ast))
        , Applicative m
        ) =>
        Proxy constraint ->
        TypeConstraintsOf ast ->
        (TypeConstraintsOf ast -> m ()) ->
        (forall child. constraint child => TypeConstraintsOf child -> Tree p child -> m (Tree q child)) ->
        Tree ast p -> m (Tree ast q)
    applyConstraints _ constraints _ update =
        children (Proxy :: Proxy (constraint `And` TypeConstraintsAre (TypeConstraintsOf ast)))
        (update constraints)

class TypeConstraintsOf ast ~ constraints => TypeConstraintsAre constraints ast
instance TypeConstraintsOf ast ~ constraints => TypeConstraintsAre constraints ast

class Monad m => ScopeConstraintsMonad c m where
    scopeConstraints :: m c
