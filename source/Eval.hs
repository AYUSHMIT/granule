-- Granule interpreter
{-# LANGUAGE ImplicitParams #-}
module Eval (eval) where

import Syntax.Expr
import Syntax.Pretty
import Syntax.Desugar
import Context
import Utils

import System.IO (hFlush, stdout)

evalBinOp :: String -> Value -> Value -> Value
evalBinOp "+" (NumInt n1) (NumInt n2) = NumInt (n1 + n2)
evalBinOp "*" (NumInt n1) (NumInt n2) = NumInt (n1 * n2)
evalBinOp "-" (NumInt n1) (NumInt n2) = NumInt (n1 - n2)
evalBinOp "+" (NumFloat n1) (NumFloat n2) = NumFloat (n1 + n2)
evalBinOp "*" (NumFloat n1) (NumFloat n2) = NumFloat (n1 * n2)
evalBinOp "-" (NumFloat n1) (NumFloat n2) = NumFloat (n1 - n2)
evalBinOp "==" (NumInt n) (NumInt m) = Constr (show (n == m)) []
evalBinOp "<=" (NumInt n) (NumInt m) = Constr (show (n <= m)) []
evalBinOp "<" (NumInt n) (NumInt m) = Constr (show (n < m)) []
evalBinOp ">=" (NumInt n) (NumInt m) = Constr (show (n >= m)) []
evalBinOp ">" (NumInt n) (NumInt m) = Constr (show (n > m)) []
evalBinOp "==" (NumFloat n) (NumFloat m) = Constr (show (n == m)) []
evalBinOp "<=" (NumFloat n) (NumFloat m) = Constr (show (n <= m)) []
evalBinOp "<" (NumFloat n) (NumFloat m) = Constr (show (n < m)) []
evalBinOp ">=" (NumFloat n) (NumFloat m) = Constr (show (n >= m)) []
evalBinOp ">" (NumFloat n) (NumFloat m) = Constr (show (n > m)) []
evalBinOp op _ _ = error $ "Unknown operator " ++ op

-- Call-by-value big step semantics
evalIn :: Ctxt Value -> Expr -> IO Value

evalIn ctxt (App _ (Val _ (Var "write")) e) = do
    v <- evalIn ctxt e
    print v
    return $ Pure (Val nullSpan v)

evalIn _ (Val s (Var "read")) = do
    putStr "> "
    hFlush stdout
    val <- readLn
    return $ Pure (Val s (NumInt val))

evalIn ctxt (App _ (Val _ (Var "pure")) e) = do
  v <- evalIn ctxt e
  return $ Pure (Val nullSpan v)

evalIn _ctxt (App _ (Val _ (Var "toFloat")) (Val _ (NumInt n))) =
  return $ NumFloat (cast n)
  where
    cast :: Int -> Double
    cast = fromInteger . toInteger


evalIn _ (Val _ (Abs x t e)) = return $ Abs x t e

evalIn ctxt (App _ e1 e2) = do
    v1 <- evalIn ctxt e1
    case v1 of
      Abs x _ e3 -> do
        v2 <- evalIn ctxt e2
        evalIn ctxt (subst (Val nullSpan v2) x e3)

      Constr c vs -> do
        v2 <- evalIn ctxt e2
        return $ Constr c (vs ++ [v2])

      _ -> error $ show v1
      -- _ -> error "Cannot apply value"

evalIn ctxt (Binop _ op e1 e2) = do
     v1 <- evalIn ctxt e1
     v2 <- evalIn ctxt e2
     return $ evalBinOp op v1 v2

evalIn ctxt (LetBox _ var _ e1 e2) = do
    v1 <- evalIn ctxt e1
    case v1 of
       Promote e1' ->
           evalIn ctxt (subst e1' var e2)
       other -> fail $ "Runtime exception: Expecting a box value but got: "
             ++ pretty other

evalIn ctxt (LetDiamond _ var _ e1 e2) = do
     v1 <- evalIn ctxt e1
     case v1 of
        Pure e -> do
          val <- evalIn ctxt e
          evalIn ctxt (subst (Val nullSpan val) var e2)
        other -> fail $ "Runtime exception: Expecting a diamonad value bug got: "
                      ++ pretty other

evalIn _ (Val _ (Var "scale")) = return
  (Abs " x" Nothing (Val nullSpan
    (Abs " y" Nothing (
      LetBox nullSpan " ye" (TyCon "Float")
         (Val nullSpan (Var " y"))
         (Binop nullSpan
           "*" (Val nullSpan (Var " x")) (Val nullSpan (Var " ye")))))))
evalIn ctxt (Val _ (Var x)) =
    case lookup x ctxt of
      Just val -> return val
      Nothing  -> fail $ "Variable '" ++ x ++ "' is undefined in context: "
               ++ show ctxt

evalIn ctxt (Val s (Pair l r)) = do
  l' <- evalIn ctxt l
  r' <- evalIn ctxt r
  return $ Pair (Val s l') (Val s r')

evalIn _ (Val _ v) = return v

evalIn ctxt (Case _ gExpr cases) = do
    val <- evalIn ctxt gExpr
    p <- pmatch cases val
    case p of
      Just (ei, bindings) -> evalIn ctxt (applyBindings bindings ei)
      Nothing             ->
        error $ "Incomplete pattern match:\n  cases: " ++ show cases ++ "\n  val: " ++ show val
  where
    applyBindings [] e = e
    applyBindings ((e', var):bs) e = applyBindings bs (subst e' var e)

    pmatch []                _                           = return Nothing
    pmatch ((PWild _, e):_)  _                           = return $ Just (e, [])
    pmatch ((PConstr _ s, e):_) (Constr s' []) | s == s' = return $ Just (e, [])
    pmatch ((PVar _ var, e):_) val                       = return $ Just (e, [(Val nullSpan val, var)])
    pmatch ((PBox _ p, e):ps) (Promote e')      = do
      v <- evalIn ctxt e'
      match <- pmatch [(p, e)] v
      case match of
        Just (_, bindings) -> return $ Just (e, bindings)
        Nothing -> pmatch ps (Promote e')

    pmatch ((PInt _ n, e):_)      (NumInt m)   | n == m   = return $ Just (e, [])
    pmatch ((PFloat _ n, e):_)    (NumFloat m) | n == m   = return $ Just (e, [])
    pmatch ((PApp _ p1 p2, e):ps) val@(Constr s vs) = do
      p <- pmatch [(p2, e)] (last vs)
      case p of
        Just (_, bindings) -> do
          p' <- pmatch [(p1, e)] (Constr s (reverse . tail . reverse $ vs))
          case p' of
            Just (_, bindings') -> return $ Just (e, bindings ++ bindings')
            _                   -> pmatch ps val
        _                  -> pmatch ps val
    pmatch ((PPair _ p1 p2, e):ps) vals@(Pair (Val _ v1) (Val _ v2)) = do
      match1 <- pmatch [(p1, e)] v1
      match2 <- pmatch [(p2, e)] v2
      case match1 of
        Nothing -> pmatch ps vals
        Just (_, bindings1) -> case match2 of
          Nothing -> pmatch ps vals
          Just (_, bindings2) -> return (Just (e, bindings1 ++ bindings2))

    pmatch (_:ps) val = pmatch ps val

evalDefs :: (?globals :: Globals) => Ctxt Value -> [Def] -> IO (Ctxt Value)
evalDefs ctxt [] = return ctxt
evalDefs ctxt (Def _ var e [] _ : defs) = do
    val <- evalIn ctxt e
    evalDefs (extend ctxt var val) defs
evalDefs ctxt (d : defs) = do
    let d' = desugar d
    debugM "Desugaring" $ pretty d'
    evalDefs ctxt (d' : defs)

eval :: (?globals :: Globals) => [Def] -> IO (Maybe Value)
eval defs = do
    bindings <- evalDefs empty defs
    case lookup "main" bindings of
      Nothing -> return Nothing
      Just (Pure e)    -> fmap Just (evalIn bindings e)
      Just (Promote e) -> fmap Just (evalIn bindings e)
      Just val         -> return $ Just val
