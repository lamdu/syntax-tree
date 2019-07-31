{-# LANGUAGE NoImplicitPrelude, TypeFamilies, DataKinds, TypeOperators #-}
{-# LANGUAGE ConstraintKinds #-}

module AST.Constraint
    ( KnotsConstraint
    , ConcatKnotConstraints
    , KnotConstraint
    ) where

import AST.Knot (Knot)
import Data.Constraint (Constraint)
import Data.Kind (Type)
import Data.TyFun

type KnotConstraint = (Knot -> Type) -> Constraint

-- | Apply a constraint on the given knots
data KnotsConstraint (ks :: [Knot -> Type]) :: KnotConstraint ~> Constraint
type instance Apply (KnotsConstraint '[]) c = ()
type instance Apply (KnotsConstraint (k ': ks)) c =
    ( c k
    , Apply (KnotsConstraint ks) c
    )

data ConcatKnotConstraints (xs :: [KnotConstraint ~> Constraint]) :: KnotConstraint ~> Constraint
type instance Apply (ConcatKnotConstraints '[]) c = ()
type instance Apply (ConcatKnotConstraints (x ': xs)) c =
    ( Apply x c
    , Apply (ConcatKnotConstraints xs) c
    )