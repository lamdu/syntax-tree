-- | Pure combinators for LangB

module LangB.Pure
    ( module LangB.Pure
    , module LangB
    ) where

import AST
import AST.Term.Apply
import AST.Term.Lam
import AST.Term.Let
import AST.Term.RowExtend
import AST.Term.Var
import Control.Lens.Operators
import LangB
import TypeLang.Pure

bVar :: String -> Tree Pure LangB
bVar = Pure . BVar . Var . Name

lam :: String -> (Tree Pure LangB -> Tree Pure LangB) -> Tree Pure LangB
lam v mk = bVar v & mk & Lam (Name v) & BLam & Pure

bLet ::
    String -> Tree Pure LangB -> (Tree Pure LangB -> Tree Pure LangB) -> Tree Pure LangB
bLet v val body = Let (Name v) val (body (bVar v)) & BLet & Pure

($$) :: Tree Pure LangB -> Tree Pure LangB -> Tree Pure LangB
x $$ y = Apply x y & BApp & Pure

bLit :: Int -> Tree Pure LangB
bLit = Pure . BLit

recExtend :: [(String, Tree Pure LangB)] -> Tree Pure LangB -> Tree Pure LangB
recExtend fields rest = foldr (fmap (Pure . BRecExtend) . uncurry (RowExtend . Name)) rest fields

closedRec :: [(String, Tree Pure LangB)] -> Tree Pure LangB
closedRec fields = recExtend fields (Pure BRecEmpty)
