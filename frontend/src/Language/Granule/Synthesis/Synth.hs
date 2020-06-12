{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms #-}

{-# options_ghc -fno-warn-incomplete-uni-patterns -Wno-deprecations #-}
module Language.Granule.Synthesis.Synth where

--import Data.List
--import Control.Monad (forM_)
--import Debug.Trace
import System.IO.Unsafe
import qualified Data.Map as M

import Language.Granule.Syntax.Def
import Language.Granule.Syntax.Expr
import Language.Granule.Syntax.Type
import Language.Granule.Syntax.SecondParameter
import Language.Granule.Syntax.Identifiers
import Language.Granule.Syntax.Pattern
import Language.Granule.Syntax.Pretty

import Language.Granule.Context

-- import Language.Granule.Checker.Checker
import Language.Granule.Checker.CoeffectsTypeConverter
import Language.Granule.Checker.Constraints
import Language.Granule.Checker.Monad
import Language.Granule.Checker.Predicates
import Language.Granule.Checker.Substitution
import Language.Granule.Checker.SubstitutionContexts
import Language.Granule.Checker.Kinds (inferCoeffectType)
import Language.Granule.Checker.Types
import Language.Granule.Checker.Variables hiding (freshIdentifierBase)
import Language.Granule.Syntax.Span
import Language.Granule.Synthesis.Refactor

import Data.Either (rights)
import Data.List.NonEmpty (NonEmpty(..))
import Control.Monad.Except
import qualified Control.Monad.State.Strict as State (get, modify)
--import Control.Monad.Trans.List
--import Control.Monad.Writer.Lazy
import Control.Monad.State.Strict
import Control.Monad.Logic

import qualified System.Clock as Clock

import Language.Granule.Utils


solve :: (?globals :: Globals)
  => Synthesiser Bool
solve = do
  cs <- conv $ State.get
  let pred = Conj $ predicateStack cs
  tyVars <- conv $ justCoeffectTypesConverted nullSpanNoFile (tyVarContext cs)
  --traceM $ pretty pred
  -- Prove the predicate
  start  <- liftIO $ Clock.getTime Clock.Monotonic
  (smtTime', result) <- liftIO $ provePredicate pred tyVars
  -- Force the result
  _ <- return $ result `seq` result
  end    <- liftIO $ Clock.getTime Clock.Monotonic
  let proverTime' = fromIntegral (Clock.toNanoSecs (Clock.diffTimeSpec end start)) / (10^(6 :: Integer)::Double)


  -- Update benchmarking data

  state <- Synthesiser $ lift $ lift $ lift get
--  traceM  $ show state
  Synthesiser $ lift $ lift $ lift $ modify (\state ->
            state {
             smtCallsCount = 1 + (smtCallsCount state),
             smtTime = smtTime' + (smtTime state),
             proverTime = proverTime' + (proverTime state),
             theoremSizeTotal = (sizeOfPred pred) + (theoremSizeTotal state)
                  })

          --  (SynthesisData 1 smtTime proverTime (sizeOfPred pred))

  case result of
    QED -> do
      return True
    NotValid s -> do
      return False
    SolverProofError msgs -> do
      return False
    OtherSolverError reason -> do
      return False
    Timeout -> do
      return False
    _ -> do
      return False

gradeAdd :: Coeffect -> Coeffect -> Maybe Coeffect
gradeAdd c c' = Just $ CPlus c c'

gradeMult :: Coeffect -> Coeffect -> Maybe Coeffect
gradeMult c c' = Just $ CTimes c c'

gradeLub :: Coeffect -> Coeffect -> Maybe Coeffect
gradeLub c c' = Just $ CJoin c c'

gradeGlb :: Coeffect -> Coeffect -> Maybe Coeffect
gradeGlb c c' = Just $ CMeet c c'

ctxtSubtract :: (?globals :: Globals) => Ctxt (Assumption)  -> Ctxt (Assumption) -> Synthesiser(Maybe (Ctxt (Assumption)))
ctxtSubtract [] [] = return $ Just []
ctxtSubtract ((x1, Linear t1):xs) ys =
  case lookup x1 ys of
    Just _ -> ctxtSubtract xs ys
    _ -> do
      ctx <- ctxtSubtract xs ys
      case ctx of
        Just ctx' -> return $ Just ((x1, Linear t1) : ctx')
        _ -> return Nothing
ctxtSubtract ((x1, Discharged t1 g1):xs) ys  =
  case lookup x1 ys of
    Just (Discharged t2 g2) -> do
      g3 <- gradeSub g2 g1
      ctx <- ctxtSubtract xs ys
      case ctx of
        Just ctx' -> return $ Just ((x1, Discharged t1 g3):ctx')
        _ -> return Nothing
    _ -> do
      ctx <- ctxtSubtract xs ys
      case ctx of
        Just ctx' -> return $ Just ((x1, Discharged t1 g1):ctx')
        _ -> return Nothing
    where
      gradeSub g g' = do
        (kind, _) <- conv $ inferCoeffectType nullSpan g
        var <- conv $ freshTyVarInContext (mkId $ "c") (KPromote kind)
        conv $ existential var (KPromote kind)
        conv $ addConstraint (ApproximatedBy nullSpanNoFile (CPlus (CVar var) g) g' kind)
        return $ CVar var
ctxtSubtract _ _ = return $ Just []

ctxtMultByCoeffect :: Coeffect -> Ctxt (Assumption) -> Maybe (Ctxt (Assumption))
ctxtMultByCoeffect _ [] = Just []
ctxtMultByCoeffect g1 ((x, Discharged t g2):xs) =
  case gradeMult g1 g2 of
    Just g' -> do
      ctxt <- ctxtMultByCoeffect g1 xs
      return $ ((x, Discharged t g'): ctxt)
    Nothing -> Nothing
ctxtMultByCoeffect _ _ = Nothing

ctxtDivByCoeffect :: (?globals :: Globals) => Coeffect -> Ctxt (Assumption) -> Synthesiser (Maybe (Ctxt (Assumption)))
ctxtDivByCoeffect _ [] = return $ Just []
ctxtDivByCoeffect g1 ((x, Discharged t g2):xs) =
    do
      ctxt <- ctxtDivByCoeffect g1 xs
      case ctxt of
        Just ctxt' -> do
          var <- gradeDiv g1 g2
          return $ Just ((x, Discharged t var): ctxt')
        _ -> return Nothing
  where
    gradeDiv g g' = do
      (kind, _) <- conv $ inferCoeffectType nullSpan g
      var <- conv $ freshTyVarInContext (mkId $ "c") (KPromote kind)
      conv $ existential var (KPromote kind)
      conv $ addConstraint (ApproximatedBy nullSpanNoFile (CTimes (CVar var) g) g' kind)
      return $ CVar var

ctxtDivByCoeffect _ _ = return Nothing

ctxtMerge :: (Coeffect -> Coeffect -> Maybe Coeffect) -> Ctxt Assumption -> Ctxt Assumption -> Maybe (Ctxt Assumption)
ctxtMerge _ [] [] = Just []
ctxtMerge _ x [] = Just x
ctxtMerge _ [] y = Just y
ctxtMerge coefOp ((x, Discharged t1 g1):xs) ys =
  case lookupAndCutout x ys of
    Just (ys', Discharged t2 g2) ->
      if t1 == t2 then
        case coefOp g1 g2 of
          Just g3 -> do
            ctxt <- ctxtMerge coefOp xs ys'
            return $ (x, Discharged t1 g3) : ctxt
          Nothing -> Nothing
      else
        Nothing
    Nothing -> do
      ctxt <- ctxtMerge coefOp xs ys
      return $ (x, Discharged t1 g1) : ctxt
    _ -> Nothing
ctxtMerge coefOp ((x, Linear t1):xs) ys =
  case lookup x ys of
    Just (Linear t2) -> ctxtMerge coefOp xs ys
    Nothing -> Nothing
    _ -> Nothing

computeAddInputCtx :: (?globals :: Globals) => Ctxt (Assumption) -> Ctxt (Assumption) -> Synthesiser (Ctxt (Assumption))
computeAddInputCtx gamma delta = do
  ctx <- ctxtSubtract gamma delta
  case ctx of
    Just ctx' -> return ctx'
    Nothing -> return []

computeAddOutputCtx :: Ctxt (Assumption) -> Ctxt (Assumption) -> Ctxt (Assumption) -> Ctxt (Assumption)
computeAddOutputCtx del1 del2 del3 = do
  case ctxtAdd del1 del2 of
    Just del' ->
      case ctxtAdd del' del3 of
          Just del'' -> del''
          _ -> []
    _ -> []

ctxtAdd :: Ctxt Assumption -> Ctxt Assumption -> Maybe (Ctxt Assumption)
ctxtAdd [] [] = Just []
ctxtAdd x [] = Just x
ctxtAdd [] y = Just y
ctxtAdd ((x, Discharged t1 g1):xs) ys =
  case lookupAndCutout x ys of
    Just (ys', Discharged t2 g2) ->
      case gradeAdd g1 g2 of
        Just g3 -> do
          ctxt <- ctxtAdd xs ys'
          return $ (x, Discharged t1 g3) : ctxt
        Nothing -> Nothing
    Nothing -> do
      ctxt <- ctxtAdd xs ys
      return $ (x, Discharged t1 g1) : ctxt
    _ -> Nothing
ctxtAdd ((x, Linear t1):xs) ys =
  case lookup x ys of
    Just (Linear t2) -> ctxtAdd xs ys
    Nothing -> do
      ctxt <- ctxtAdd xs ys
      return $ (x, Linear t1) : ctxt
    _ -> Nothing

pattern ProdTy :: Type -> Type -> Type
pattern ProdTy t1 t2 = TyApp (TyApp (TyCon (Id "," ",")) t1) t2

pattern SumTy :: Type -> Type -> Type
pattern SumTy t1 t2  = TyApp (TyApp (TyCon (Id "Either" "Either")) t1) t2

isRAsync :: Type -> Bool
isRAsync (FunTy {}) = True
isRAsync _ = False

isLAsync :: Type -> Bool
isLAsync (ProdTy{}) = True
isLAsync (SumTy{}) = True
isLAsync (Box{}) = True
isLAsync _ = False

isAtomic :: Type -> Bool
isAtomic (TyVar {}) = True
isAtomic _ = False

-- Data structure for collecting information about synthesis
data SynthesisData =
  SynthesisData {
    smtCallsCount    :: Integer
  , smtTime          :: Double
  , proverTime       :: Double -- longer than smtTime as it includes compilation of predicates to SMT
  , theoremSizeTotal :: Integer
  }
  deriving Show

instance Semigroup SynthesisData where
 (SynthesisData calls stime time size) <> (SynthesisData calls' stime' time' size') =
    SynthesisData (calls + calls') (stime + stime') (time + time') (size + size')

instance Monoid SynthesisData where
  mempty  = SynthesisData 0 0 0 0
  mappend = (<>)

-- Synthesiser monad

newtype Synthesiser a = Synthesiser
  { unSynthesiser ::
      ExceptT (NonEmpty CheckerError) (StateT CheckerState (LogicT (StateT SynthesisData IO))) a }
  deriving (Functor, Applicative, MonadState CheckerState)

-- Synthesiser always uses fair bind from LogicT
instance Monad Synthesiser where
  return = Synthesiser . return
  k >>= f =
    Synthesiser $ ExceptT (StateT
       (\s -> unSynth k s >>- (\(eb, s) ->
          case eb of
            Left r -> mzero
            Right b -> (unSynth . f) b s)))

     where
       unSynth m = runStateT (runExceptT (unSynthesiser m))

-- Monad transformer definitions

instance MonadIO Synthesiser where
  liftIO = conv . liftIO

--tellMe :: SynthesisData -> Synthesiser ()
--tellMe d = Synthesiser (ExceptT (StateT (\s -> LogicT (StateT (\s' -> return ([(Right (), s)], d) s')))))

-- Wrapper/unwrapper
--mkSynthesiser ::
--     (CheckerState -> LogicT IO ((Either (NonEmpty CheckerError) a), CheckerState))
--  -> Synthesiser a
--mkSynthesiser x = Synthesiser (ExceptT (StateT (\s -> x s)))

runSynthesiser :: Synthesiser a
  -> (CheckerState -> StateT SynthesisData IO [((Either (NonEmpty CheckerError) a), CheckerState)])
runSynthesiser m s = do
  observeManyT 1 (runStateT (runExceptT (unSynthesiser m)) s)

--foo :: Synthesiser Int
--foo = do
--  tellMe (SynthesisData 10 10 10 10)
--  none

conv :: Checker a -> Synthesiser a
conv (Checker k) =
  Synthesiser
    (ExceptT
         (StateT (\s -> lift $ lift (runStateT (runExceptT k) s))))


try :: Synthesiser a -> Synthesiser a -> Synthesiser a
try m n = do
  Synthesiser $ ExceptT ((runExceptT (unSynthesiser m)) `interleave` (runExceptT (unSynthesiser n)))

none :: Synthesiser a
none = Synthesiser (ExceptT mzero)

data BoxRuleMode = Default | Alternative
  deriving (Show, Eq)

data ResourceScheme a = Additive | Subtractive a
  deriving (Show, Eq)

testGlobals :: Globals
testGlobals = mempty
  { globalsNoColors = Just True
  , globalsSuppressInfos = Just True
  , globalsTesting = Just True
  }


testSyn :: Bool -> IO ()
testSyn useReprint =
  let ty =
--        FunTy Nothing (Box (CInterval (CNat 2) (CNat 3)) (TyVar $ mkId "b") ) (FunTy Nothing (SumTy (TyVar $ mkId "a") (TyVar $ mkId "c")) (SumTy (ProdTy (TyVar $ mkId "a") (Box (CInterval (CNat 2) (CNat 2)) (TyVar $ mkId "b") )) (ProdTy (TyVar $ mkId "c") (Box (CInterval (CNat 3) (CNat 3)) (TyVar $ mkId "b") ))))
--        FunTy Nothing (TyVar $ mkId "a") (SumTy (TyVar $ mkId "b") (TyVar $ mkId "a"))
        FunTy Nothing (Box (CNat 3) (TyVar $ mkId "a")) (FunTy Nothing (Box (CNat 6) (TyVar $ mkId "b") ) (Box (CNat 3) (ProdTy (ProdTy (TyVar $ mkId "b") (TyVar $ mkId "b")) (TyVar $ mkId "a")) ))
--        FunTy Nothing (Box (CNat 2) (TyVar $ mkId "a")) (ProdTy (TyVar $ mkId "a") (TyVar $ mkId "a"))
--        FunTy Nothing (FunTy Nothing (TyVar $ mkId "a") (FunTy Nothing (TyVar $ mkId "b") (TyVar $ mkId "c"))) (FunTy Nothing (TyVar $ mkId "b") (FunTy Nothing (TyVar $ mkId "a") (TyVar $ mkId "c")))
--        FunTy Nothing (TyVar $ mkId "a") (TyVar $ mkId "a")
--        FunTy Nothing (Box (CNat 2) (TyVar $ mkId "a")) (ProdTy (TyVar $ mkId "a") (TyVar $ mkId "a"))
        in
    let ts = (Forall nullSpanNoFile [(mkId "a", KType), (mkId "b", KType), (mkId "c", KType)] [] ty) in
    let ?globals = testGlobals in do
     -- State.modify (\st -> st { tyVarContext = map (\(n, c) -> (n, (c, ForallQ))) [(mkId "a", KType)]})
    let res = testOutput $ topLevel ts (Subtractive Default) in -- [(mkId "y", Linear (TyVar $ mkId "b")), (mkId "x", Linear (TyVar $ mkId "a"))] [] ty
        if length res == 0
        then  (putStrLn "No inhabitants found.")
        else  (forM_ res (\(ast, _, sub) -> putStrLn $
                           (if useReprint then pretty (reprintAsDef (mkId "f") ts ast) else pretty ast) ++ "\n" ++ (show sub) ))

testOutput :: Synthesiser a -> [a]
testOutput res =
  rights $ map fst $ fst $ unsafePerformIO $ runStateT (runSynthesiser res initState) mempty

--testData :: Synthesiser a -> SynthesisData
--testData res =
--  snd $ unsafePerformIO $ runSynthesiser res initState

topLevel :: (?globals :: Globals) => TypeScheme -> ResourceScheme BoxRuleMode -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
topLevel ts@(Forall _ binders constraints ty) resourceScheme = do
  conv $ State.modify (\st -> st { tyVarContext = map (\(n, c) -> (n, (c, ForallQ))) binders})
  synthesise [] True resourceScheme [] [] ts

-- Reprint Expr as a top-level declaration
reprintAsDef :: Id -> TypeScheme -> Expr () Type -> Def () Type
reprintAsDef id goalTy expr =
  refactorDef $
    Def
      { defSpan = nullSpanNoFile,
        defId = id,
        defRefactored = False,
        defEquations =
          EquationList
            { equationsSpan = nullSpanNoFile,
              equationsId = id,
              equationsRefactored = False,
              equations =
              [ Equation
                { equationSpan = nullSpanNoFile,
                  equationId = id,
                  equationRefactored = True,
                  equationAnnotation = getSecondParameter expr,
                  equationPatterns = [],
                  equationBody = expr
                }
              ]
            }
          ,
      defTypeScheme = goalTy
      }

makeVar :: Id -> TypeScheme -> Expr () Type
makeVar name (Forall _ _ _ t) =
  Val s t False (Var t name)
  where s = nullSpanNoFile

makeAbs :: Id -> Expr () Type -> TypeScheme -> Expr () Type
makeAbs name e (Forall _ _ _ t@(FunTy _ t1 t2)) =
  Val s t False (Abs t (PVar s t False name) (Just t1) e)
  where s = nullSpanNoFile
makeAbs name e _ = error "Cannot synth here" -- TODO: better error handling

makeApp :: Id -> Expr () Type -> TypeScheme -> Type -> Expr () Type
makeApp name e (Forall _ _ _ t1) t2 =
  App s t1 False (makeVar name (Forall nullSpanNoFile [] [] t2)) e
  where s = nullSpanNoFile

makeBox :: TypeScheme -> Expr () Type -> Expr () Type
makeBox (Forall _ _ _ t) e =
  Val s t False (Promote t e)
  where s = nullSpanNoFile

makeUnbox :: Id -> Id -> TypeScheme -> Type -> Type -> Expr () Type -> Expr () Type
makeUnbox name1 name2 (Forall _ _ _ goalTy) boxTy varTy e  =
  App s goalTy False
  (Val s boxTy False
    (Abs (FunTy Nothing boxTy goalTy)
      (PBox s boxTy False
        (PVar s varTy False name1)) (Just boxTy) e))
  (Val s varTy False
    (Var varTy name2))
  where s = nullSpanNoFile

makePair :: Type -> Type -> Expr () Type -> Expr () Type -> Expr () Type
makePair lTy rTy e1 e2 =
  App s rTy False (App s lTy False (Val s (ProdTy lTy rTy) False (Constr (ProdTy lTy rTy) (mkId ",") [])) e1) e2
  where s = nullSpanNoFile

makePairElim :: Id -> Id -> Id -> TypeScheme -> Type -> Type -> Expr () Type -> Expr () Type
makePairElim name lId rId (Forall _ _ _ goalTy) lTy rTy e =
  App s goalTy False
  (Val s (ProdTy lTy rTy) False
    (Abs (FunTy Nothing (ProdTy lTy rTy) goalTy)
      (PConstr s (ProdTy lTy rTy) False (mkId ",") [(PVar s lTy False lId), (PVar s rTy False rId)] )
        Nothing e))
  (Val s (ProdTy lTy rTy) False (Var (ProdTy lTy rTy) name))
  where s = nullSpanNoFile

makeEitherLeft :: Type -> Type -> Expr () Type -> Expr () Type
makeEitherLeft lTy rTy e  =
  (App s lTy False (Val s (SumTy lTy rTy) False (Constr (SumTy lTy rTy) (mkId "Left") [])) e)
  where s = nullSpanNoFile

makeEitherRight :: Type -> Type -> Expr () Type -> Expr () Type
makeEitherRight lTy rTy e  =
  (App s rTy False (Val s (SumTy lTy rTy) False (Constr (SumTy lTy rTy) (mkId "Right") [])) e)
  where s = nullSpanNoFile

makeCase :: Type -> Type -> Id -> Id -> Id -> Expr () Type -> Expr () Type -> Expr () Type
makeCase t1 t2 sId lId rId lExpr rExpr =
  Case s (SumTy t1 t2) False (Val s (SumTy t1 t2) False (Var (SumTy t1 t2) sId)) [(PConstr s (SumTy t1 t2) False (mkId "Left") [(PVar s t1 False lId)], lExpr), (PConstr s (SumTy t1 t2) False (mkId "Right") [(PVar s t2 False rId)], rExpr)]
  where s = nullSpanNoFile

--makeEitherCase :: Id -> Id -> Id -> TypeScheme -> Type -> Type -> Expr () Type
--makeEitherCase name lId rId (Forall _ _ _ goalTy) lTy rTy =

useVar :: (?globals :: Globals) => (Id, Assumption) -> Ctxt (Assumption) -> ResourceScheme BoxRuleMode -> Synthesiser (Bool, Ctxt (Assumption), Type)
useVar (name, Linear t) gamma Subtractive{} = return (True, gamma, t)
useVar (name, Discharged t grade) gamma Subtractive{} = do
  (kind, _) <- conv $ inferCoeffectType nullSpan grade
  var <- conv $ freshTyVarInContext (mkId $ "c") (KPromote kind)
  conv $ existential var (KPromote kind)
  --conv $ addPredicate (Impl [] (Con (Neq nullSpanNoFile (CZero kind) grade kind))
  --                             (Con (ApproximatedBy nullSpanNoFile (CPlus (CVar var) (COne kind)) grade kind)))
  conv $ addConstraint (ApproximatedBy nullSpanNoFile (CPlus (CVar var) (COne kind)) grade kind)
  res <- solve
  case res of
    True -> do
      return (True, replace gamma name (Discharged t (CVar var)), t)
    False -> do
      return (False, [], t)
useVar (name, Linear t) _ Additive = return (True, [(name, Linear t)], t)
useVar (name, Discharged t grade) _ Additive = do
  (kind, _) <- conv $ inferCoeffectType nullSpan grade
  return (True, [(name, (Discharged t (COne kind)))], t)

varHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> ResourceScheme BoxRuleMode
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
varHelper decls left [] _ _ = none
varHelper decls left (var@(x, a) : right) resourceScheme goalTy@(Forall _ binders constraints goalTy') =
 (varHelper decls (var:left) right resourceScheme goalTy) `try`
   (do
--    liftIO $ putStrLn $ "synth eq on (" <> pretty var <> ") " <> pretty t <> " and " <> pretty goalTy'
      (success, specTy, subst) <- conv $ equalTypes nullSpanNoFile (getAssumptionType a) goalTy'
      case success of
        True -> do
          (canUse, gamma, t) <- useVar var (left ++ right) resourceScheme
          if canUse
            then return (makeVar x goalTy, gamma, subst)
            else none
        _ -> none)

absHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> Bool
  -> ResourceScheme BoxRuleMode
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
absHelper decls gamma omega allowLam resourceScheme goalTy =
  case goalTy of
      (Forall _ binders constraints (FunTy name t1 t2)) -> do
        id <- useBinderNameOrFreshen name
        let (gamma', omega') =
              if isLAsync t1 then
                (gamma, ((id, Linear t1):omega))
              else
                (((id, Linear t1):gamma, omega))
        (e, delta, subst) <- synthesiseInner decls True resourceScheme gamma' omega' (Forall nullSpanNoFile binders constraints t2)
        case (resourceScheme, lookupAndCutout id delta) of
          (Additive, Just (delta', Linear _)) ->
            return (makeAbs id e goalTy, delta', subst)
          (Subtractive{}, Nothing) ->
            return (makeAbs id e goalTy, delta, subst)
          _ -> none
      _ -> none


appHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> ResourceScheme BoxRuleMode
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
appHelper decls left [] _ _ = none
appHelper decls left (var@(x, a) : right) (sub@Subtractive{}) goalTy@(Forall _ binders constraints _ ) =
  (appHelper decls (var : left) right sub goalTy) `try`
  let omega = left ++ right in do
  (canUse, omega', t) <- useVar var omega sub
  case (canUse, t) of
    (True, FunTy _ t1 t2) -> do
        id <- freshIdentifier
        let (gamma', omega'') = bindToContext (id, Linear t2) omega' [] (isLAsync t2)
        (e1, delta1, sub1) <- synthesiseInner decls True sub gamma' omega'' goalTy
        (e2, delta2, sub2) <- synthesiseInner decls True sub delta1 [] (Forall nullSpanNoFile binders constraints t1)
        subst <- conv $ combineSubstitutions nullSpanNoFile sub1 sub2
        case lookup id delta2 of
          Nothing ->
            return (Language.Granule.Syntax.Expr.subst (makeApp x e2 goalTy t) id e1, delta2, subst)
          _ -> none
    _ -> none
appHelper decls left (var@(x, a) : right) Additive goalTy@(Forall _ binders constraints _ ) =
  (appHelper decls (var : left) right Additive goalTy) `try`
  let omega = left ++ right in do
    (canUse, omega', t) <- useVar var omega Additive
    case (canUse, t) of
      (True, FunTy _ t1 t2) -> do
        id <- freshIdentifier
        gamma1 <- computeAddInputCtx omega omega'
        let (gamma1', omega'') = bindToContext (id, Linear t2) gamma1 [] (isLAsync t2)
        (e1, delta1, sub1) <- synthesiseInner decls True Additive gamma1' omega'' goalTy
        gamma2 <- computeAddInputCtx gamma1' delta1
        (e2, delta2, sub2) <- synthesiseInner decls True Additive gamma2 [] (Forall nullSpanNoFile binders constraints t1)
        let delta3 = computeAddOutputCtx omega' delta1 delta2
        subst <- conv $ combineSubstitutions nullSpan sub1 sub2
        case lookupAndCutout id delta3 of
          Just (delta3', Linear _) ->
                return (Language.Granule.Syntax.Expr.subst (makeApp x e2 goalTy t) id e1, delta3', subst)
          _ -> none
      _ -> none


boxHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> ResourceScheme BoxRuleMode
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
boxHelper decls gamma resourceScheme goalTy =
  case goalTy of
    (Forall _ binders constraints (Box g t)) -> do
      case resourceScheme of
        Additive ->
          do
            (e, delta, subst) <- synthesiseInner decls True resourceScheme gamma [] (Forall nullSpanNoFile binders constraints t)
            case ctxtMultByCoeffect g delta of
              Just delta' -> do
                return (makeBox goalTy e, delta', subst)
              _ -> none
        Subtractive Default ->
          do
            (e, delta, subst) <- synthesiseInner decls True resourceScheme gamma [] (Forall nullSpanNoFile binders constraints t)
            used <- ctxtSubtract gamma delta
            -- Compute what was used to synth e
            case used of
              Just used' -> do
                case ctxtMultByCoeffect g used' of
                  Just delta' -> do
                    delta'' <- ctxtSubtract gamma delta'
                    case delta'' of
                      Just delta''' -> do
                        return (makeBox goalTy e, delta''', subst)
                      Nothing -> none
                  _ -> none
              _ -> none
        Subtractive Alternative -> do
          gamma' <- ctxtDivByCoeffect g gamma
          case gamma' of
            Just gamma'' -> do
              (e, delta, subst) <- synthesiseInner decls True resourceScheme gamma'' [] (Forall nullSpanNoFile binders constraints t)
              case ctxtMultByCoeffect g delta of
                Just delta' -> do
                  res <- solve
                  case res of
                    True -> do
                      return (makeBox goalTy e, delta', subst)
                    False -> none
                _ -> none
            _ -> none
    _ -> none


unboxHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> ResourceScheme BoxRuleMode
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
unboxHelper decls left [] _ _ _ = none
unboxHelper decls left (var@(x, a) : right) gamma (sub@Subtractive{}) goalTy =
  (unboxHelper decls (var : left) right gamma sub goalTy) `try`
    let omega = left ++ right in do
      (canUse, omega', t) <- useVar var omega sub
      case (canUse, t) of
        (True, Box grade t') -> do
          id <- freshIdentifier
          let (gamma', omega'') = bindToContext (id, Discharged t' grade) gamma omega' (isLAsync t')
          (e, delta, subst) <- synthesiseInner decls True sub gamma' omega'' goalTy
          case lookupAndCutout id delta of
            Just (delta', (Discharged _ usage)) -> do
              (kind, _) <- conv $ inferCoeffectType nullSpan usage
              conv $ addConstraint (ApproximatedBy nullSpanNoFile (CZero kind) usage kind)
              res <- solve
              case res of
                True ->
                  return (makeUnbox id x goalTy t t' e, delta', subst)
                False -> do
                  none
            _ -> none
        _ -> none
unboxHelper decls left (var@(x, a) : right) gamma Additive goalTy =
    (unboxHelper decls (var : left) right gamma Additive goalTy) `try`
    let omega = left ++ right in do
      (canUse, omega', t) <- useVar var omega Additive
      case (canUse, t) of
        (True, Box grade t') -> do
           id <- freshIdentifier
           omega1 <- computeAddInputCtx omega omega'
           let (gamma', omega1') = bindToContext (id, Discharged t' grade) gamma omega1 (isLAsync t')
           (e, delta, subst) <- synthesiseInner decls True Additive gamma' omega1' goalTy
           let delta' = computeAddOutputCtx omega' delta []
           case lookupAndCutout id delta' of
             Just (delta'', (Discharged _ usage)) -> do
               (kind, _) <- conv $ inferCoeffectType nullSpan grade
               conv $ addConstraint (ApproximatedBy nullSpanNoFile usage grade kind)
               res <- solve
               case res of
                 True ->
                   return (makeUnbox id x goalTy t t' e,  delta'', subst)
                 False -> none
             _ -> do
               (kind, _) <- conv $ inferCoeffectType nullSpan grade
               conv $ addConstraint (ApproximatedBy nullSpanNoFile (CZero kind) grade kind)
               res <- solve
               case res of
                 True ->
                   return (makeUnbox id x goalTy t t' e,  delta', subst)
                 False -> none
        _ -> none


pairElimHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> ResourceScheme BoxRuleMode
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
pairElimHelper decls left [] _ _ _ = none
pairElimHelper decls left (var@(x, a):right) gamma (sub@Subtractive{}) goalTy =
  (pairElimHelper decls (var:left) right gamma sub goalTy) `try`
  let omega = left ++ right in do
    (canUse, omega', t) <- useVar var omega sub
    case (canUse, t) of
      (True, ProdTy t1 t2) -> do
          lId <- freshIdentifier
          rId <- freshIdentifier
          let (gamma', omega'') = bindToContext (lId, Linear t1) gamma omega' (isLAsync t1)
          let (gamma'', omega''') = bindToContext (rId, Linear t2) gamma' omega'' (isLAsync t2)
          (e, delta, subst) <- synthesiseInner decls True sub gamma'' omega''' goalTy
          case (lookup lId delta, lookup rId delta) of
            (Nothing, Nothing) -> return (makePairElim x lId rId goalTy t1 t2 e, delta, subst)
            _ -> none
      _ -> none
pairElimHelper decls left (var@(x, a):right) gamma Additive goalTy =
  (pairElimHelper decls (var:left) right gamma Additive goalTy) `try`
  let omega = left ++ right in do
    (canUse, omega', t) <- useVar var omega Additive
    case (canUse, t) of
      (True, ProdTy t1 t2) -> do
          lId <- freshIdentifier
          rId <- freshIdentifier
          omega1 <- computeAddInputCtx omega omega'
          let (gamma', omega1') = bindToContext (lId, Linear t1) gamma omega1 (isLAsync t1)
          let (gamma'', omega1'') = bindToContext (rId, Linear t2) gamma' omega1' (isLAsync t2)
          (e, delta, subst) <- synthesiseInner decls True Additive gamma'' omega1'' goalTy
          let delta' = computeAddOutputCtx omega' delta []
          case lookupAndCutout lId delta' of
            Just (delta', Linear _) ->
              case lookupAndCutout rId delta' of
                Just (delta''', Linear _) -> return (makePairElim x lId rId goalTy t1 t2 e, delta''', subst)
                _ -> none
            _ -> none
      _ -> none

unitIntroHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> ResourceScheme BoxRuleMode
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
unitIntroHelper decls gamma resourceScheme goalTy =
  case goalTy of
    (Forall _ binders constraints (TyCon (internalName -> "()"))) -> do
      let unitVal = Val nullSpan (TyCon (mkId "()")) True
                      (Constr (TyCon (mkId "()")) (mkId "()") [])
      case resourceScheme of
        Additive -> return (unitVal, [], [])
        Subtractive{} -> return (unitVal, gamma, [])
    _ -> none

pairIntroHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> ResourceScheme BoxRuleMode
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
pairIntroHelper decls gamma resourceScheme goalTy =
  case goalTy of
    (Forall _ binders constraints (ProdTy t1 t2)) -> do
      --liftIO $ putStrLn "Doing pair intro helper"
      --liftIO $ putStrLn $ show gamma
      (e1, delta1, subst1) <- synthesiseInner decls True resourceScheme gamma [] (Forall nullSpanNoFile binders constraints t1)
      gammaAdd <- computeAddInputCtx gamma delta1
      (e2, delta2, subst2) <- synthesiseInner decls True resourceScheme (if resourceScheme == Additive then gammaAdd else delta1) [] (Forall nullSpanNoFile binders constraints t2)
      let delta3 = if resourceScheme == Additive then computeAddOutputCtx delta1 delta2 [] else delta2
      subst <- conv $ combineSubstitutions nullSpanNoFile subst1 subst2
      return (makePair t1 t2 e1 e2, delta3, subst)
    _ -> none


sumIntroHelper :: (?globals :: Globals)
  => Ctxt (DataDecl) -> Ctxt (Assumption) -> ResourceScheme BoxRuleMode -> TypeScheme -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
sumIntroHelper decls gamma resourceScheme goalTy =
  case goalTy of
    (Forall _ binders constraints (SumTy t1 t2)) -> do
      try
        (do
            (e1, delta1, subst1) <- synthesiseInner decls True resourceScheme gamma [] (Forall nullSpanNoFile binders constraints t1)
            return (makeEitherLeft t1 t2 e1, delta1, subst1)

        )
        (do
            (e2, delta2, subst2) <- synthesiseInner decls True resourceScheme gamma [] (Forall nullSpanNoFile binders constraints t2)
            return (makeEitherRight t1 t2 e2, delta2, subst2)

        )
    _ -> none


sumElimHelper :: (?globals :: Globals)
  => Ctxt (DataDecl)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> Ctxt (Assumption)
  -> ResourceScheme BoxRuleMode
  -> TypeScheme
  -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
sumElimHelper decls left [] _ _ _ = none
sumElimHelper decls left (var@(x, a):right) gamma (sub@Subtractive{}) goalTy =
  (sumElimHelper decls (var:left) right gamma sub goalTy) `try`
  let omega = left ++ right in do
  (canUse, omega', t) <- useVar var omega sub
  case (canUse, t) of
    (True, SumTy t1 t2) -> do
      l <- freshIdentifier
      r <- freshIdentifier
      let (gamma', omega'') = bindToContext (l, Linear t1) gamma omega' (isLAsync t1)
      let (gamma'', omega''') = bindToContext (r, Linear t2) gamma omega' (isLAsync t2)
      (e1, delta1, subst1) <- synthesiseInner decls True sub gamma' omega'' goalTy
      (e2, delta2, subst2) <- synthesiseInner decls True sub gamma'' omega''' goalTy
      subst <- conv $ combineSubstitutions nullSpanNoFile subst1 subst2
      case (lookup l delta1, lookup r delta2) of
          (Nothing, Nothing) ->
            case ctxtMerge gradeGlb delta1 delta2 of
              Just delta3 ->
                return (makeCase t1 t2 x l r e1 e2, delta3, subst)
              Nothing -> none
          _ -> none
    _ -> none

sumElimHelper decls left (var@(x, a):right) gamma Additive goalTy =
  (sumElimHelper decls (var:left) right gamma Additive goalTy) `try`
  let omega = left ++ right in do
  (canUse, omega', t) <- useVar var omega Additive
  case (canUse, t) of
    (True, SumTy t1 t2) -> do
      l <- freshIdentifier
      r <- freshIdentifier
      omega1 <- computeAddInputCtx omega omega'
      let (gamma', omega1') = bindToContext (l, Linear t1) gamma omega1 (isLAsync t1)
      let (gamma'', omega1'') = bindToContext (r, Linear t2) gamma omega1 (isLAsync t2)
      (e1, delta1, subst1) <- synthesiseInner decls True Additive gamma' omega1' goalTy
      (e2, delta2, subst2) <- synthesiseInner decls True Additive gamma'' omega1'' goalTy
      subst <- conv $ combineSubstitutions nullSpanNoFile subst1 subst2
      case (lookupAndCutout l delta1, lookupAndCutout r delta2) of
          (Just (delta1', Linear _), Just (delta2', Linear _)) ->
            case ctxtMerge gradeLub delta1' delta2' of
              Just delta3 ->
                let delta3' = computeAddOutputCtx omega' delta3 [] in do
                   return (makeCase t1 t2 x l r e1 e2, delta3', subst)
              Nothing -> none
          _ -> none
    _ -> none



synthesiseInner :: (?globals :: Globals)
           => Ctxt (DataDecl)      -- ADT Definitions
           -> Bool                 -- whether a function is allowed at this point
           -> ResourceScheme BoxRuleMode      -- whether the synthesis is in additive mode or not
           -> Ctxt (Assumption)    -- (unfocused) free variables
           -> Ctxt (Assumption)    -- focused variables
           -> TypeScheme           -- type from which to synthesise
           -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)

synthesiseInner decls allowLam resourceScheme gamma omega goalTy@(Forall _ binders _ goalTy') =
  case (isRAsync goalTy', omega) of
    (True, omega) ->
      -- Right Async : Decompose goalTy until synchronous
      absHelper decls gamma omega allowLam resourceScheme goalTy `try` none
    (False, omega@(x:xs)) ->
      -- Left Async : Decompose assumptions until they are synchronous (eliminators on assumptions)
      unboxHelper decls [] omega gamma resourceScheme goalTy
      `try`
      pairElimHelper decls [] omega gamma resourceScheme goalTy
      `try`
      sumElimHelper decls [] omega gamma resourceScheme goalTy
    (False, []) ->
      -- Transition to synchronous (focused) search
      if isAtomic goalTy' then
        -- Left Sync: App rule + Init rules
        varHelper decls [] gamma resourceScheme goalTy
        `try`
        appHelper decls [] gamma resourceScheme goalTy
      else
        -- Right Sync : Focus on goalTy
        sumIntroHelper decls gamma resourceScheme goalTy
        `try`
        pairIntroHelper decls gamma resourceScheme goalTy
        `try`
        boxHelper decls gamma resourceScheme goalTy
        `try`
        unitIntroHelper decls gamma resourceScheme goalTy

synthesise :: (?globals :: Globals)
           => Ctxt (DataDecl)      -- ADT Definitions
           -> Bool                 -- whether a function is allowed at this point
           -> ResourceScheme BoxRuleMode      -- whether the synthesis is in additive mode or not
           -> Ctxt (Assumption)    -- (unfocused) free variables
           -> Ctxt (Assumption)    -- focused variables
           -> TypeScheme           -- type from which to synthesise
           -> Synthesiser (Expr () Type, Ctxt (Assumption), Substitution)
synthesise decls allowLam resourceScheme gamma omega goalTy = do
  result@(expr, ctxt, subst) <- synthesiseInner decls allowLam resourceScheme gamma omega goalTy
  case resourceScheme of
    Subtractive{} -> do
      -- All linear variables should be gone
      -- and all graded should approximate 0
      consumed <- mapM (\(id, a) ->
                    case a of
                      Linear{} -> return False;
                      Discharged _ grade -> do
                        (kind, _) <-  conv $ inferCoeffectType nullSpan grade
                        conv $ addConstraint (ApproximatedBy nullSpanNoFile (CZero kind) grade kind)
                        solve) ctxt
      if and consumed
        then return result
        else none

    Additive -> do
      consumed <- mapM (\(id, a) ->
                    case lookup id gamma of
                      Just (Linear{}) -> return True;
                      Just (Discharged _ grade) ->
                        case a of
                          Discharged _ grade' -> do
                            (kind, _) <- conv $ inferCoeffectType nullSpan grade
                            conv $ addConstraint (ApproximatedBy nullSpanNoFile grade' grade kind)
                            solve
                          _ -> return False
                      Nothing -> return False) ctxt
      if and consumed
        then return result
        else none

-- Run from the checker
synthesiseProgram :: (?globals :: Globals)
           => Ctxt (DataDecl)      -- ADT Definitions
           -> ResourceScheme BoxRuleMode       -- whether the synthesis is in additive mode or not
           -> Ctxt (Assumption)    -- (unfocused) free variables
           -> Ctxt (Assumption)    -- focused variables
           -> TypeScheme           -- type from which to synthesise
           -> CheckerState
           -> IO [(Expr () Type, Ctxt (Assumption), Substitution)]
synthesiseProgram decls resourceScheme gamma omega goalTy checkerState = do
  start <- liftIO $ Clock.getTime Clock.Monotonic
  -- %%
  let synRes = synthesise decls True resourceScheme gamma omega goalTy
  (synthResults, aggregate) <- (runStateT (runSynthesiser synRes checkerState) mempty)
  let results = rights (map fst synthResults)
  -- Force eval of first result (if it exists) to avoid any laziness when benchmarking
  () <- when benchmarking $ unless (null results) (return $ seq (show $ head results) ())
  -- %%
  end    <- liftIO $ Clock.getTime Clock.Monotonic

  -- <benchmarking-output>
  if benchmarking
    then do
      -- Output raw data (used for performance evaluation)
      if benchmarkingRawData then do
        putStrLn $ "Measurement "
              <> "{ smtCalls = " <> (show $ smtCallsCount aggregate)
              <> ", synthTime = " <> (show $ fromIntegral (Clock.toNanoSecs (Clock.diffTimeSpec end start)) / (10^(6 :: Integer)::Double))
              <> ", proverTime = " <> (show $ proverTime aggregate)
              <> ", solverTime = " <> (show $ Language.Granule.Synthesis.Synth.smtTime aggregate)
              <> ", meanTheoremSize = " <> (show $ if (smtCallsCount aggregate) == 0 then 0 else (fromInteger $ theoremSizeTotal aggregate) / (fromInteger $ smtCallsCount aggregate))
              <> ", success = " <> (if length results == 0 then "False" else "True")
              <> " } "
      else do
        -- Output benchmarking info
        putStrLn $ "-------------------------------------------------"
        putStrLn $ "Result = " ++ (case synthResults of ((Right (expr, _, _), _):_) -> pretty $ expr; _ -> "NO SYNTHESIS")
        putStrLn $ "-------- Synthesiser benchmarking data (" ++ show resourceScheme ++ ") -------"
        putStrLn $ "Total smtCalls     = " ++ (show $ smtCallsCount aggregate)
        putStrLn $ "Total smtTime    (ms) = "  ++ (show $ Language.Granule.Synthesis.Synth.smtTime aggregate)
        putStrLn $ "Total proverTime (ms) = "  ++ (show $ proverTime aggregate)
        putStrLn $ "Total synth time (ms) = "  ++ (show $ fromIntegral (Clock.toNanoSecs (Clock.diffTimeSpec end start)) / (10^(6 :: Integer)::Double))
        putStrLn $ "Mean theoremSize   = " ++ (show $ (if (smtCallsCount aggregate) == 0 then 0 else fromInteger $ theoremSizeTotal aggregate) / (fromInteger $ smtCallsCount aggregate))
    else return ()
  -- </benchmarking-output>
  return results

useBinderNameOrFreshen :: Maybe Id -> Synthesiser Id
useBinderNameOrFreshen Nothing = freshIdentifier
useBinderNameOrFreshen (Just n) = return n

freshIdentifier :: Synthesiser Id
freshIdentifier = do
  let mappo = ["x","y","z","u","v","w","p","q"]
  let base = "x"
  checkerState <- get
  let vmap = uniqueVarIdCounterMap checkerState
  case M.lookup base vmap of
    Nothing -> do
      let vmap' = M.insert base 1 vmap
      put checkerState { uniqueVarIdCounterMap = vmap' }
      return $ mkId base

    Just n -> do
      let vmap' = M.insert base (n+1) vmap
      put checkerState { uniqueVarIdCounterMap = vmap' }
      let n' = fromInteger . toInteger $ n
      if n' < length mappo
        then return $ mkId $ mappo !! n'
        else return $ mkId $ base <> show n'

sizeOfPred :: Pred -> Integer
sizeOfPred (Conj ps) = 1 + (sum $ map sizeOfPred ps)
sizeOfPred (Disj ps) = 1 + (sum $ map sizeOfPred ps)
sizeOfPred (Impl _ p1 p2) = 1 + (sizeOfPred p1) + (sizeOfPred p2)
sizeOfPred (Con c) = sizeOfConstraint c
sizeOfPred (NegPred p) = 1 + (sizeOfPred p)
sizeOfPred (Exists _ _ p) = 1 + (sizeOfPred p)

sizeOfConstraint :: Constraint -> Integer
sizeOfConstraint (Eq _ c1 c2 _) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)
sizeOfConstraint (Neq _ c1 c2 _) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)
sizeOfConstraint (ApproximatedBy _ c1 c2 _) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)
sizeOfConstraint (Lub _ c1 c2 c3 _) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2) + (sizeOfCoeffect c3)
sizeOfConstraint (NonZeroPromotableTo _ _ c _) = 1 + (sizeOfCoeffect c)
sizeOfConstraint (Lt _ c1 c2) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)
sizeOfConstraint (Gt _ c1 c2) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)
sizeOfConstraint (LtEq _ c1 c2) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)
sizeOfConstraint (GtEq _ c1 c2) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)

sizeOfCoeffect :: Coeffect -> Integer
sizeOfCoeffect (CPlus c1 c2) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)
sizeOfCoeffect (CTimes c1 c2) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)
sizeOfCoeffect (CMinus c1 c2) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)
sizeOfCoeffect (CMeet c1 c2) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)
sizeOfCoeffect (CJoin c1 c2) = 1 + (sizeOfCoeffect c1) + (sizeOfCoeffect c2)
sizeOfCoeffect (CZero _) = 0
sizeOfCoeffect (COne _) = 0
sizeOfCoeffect (CVar _) = 0
sizeOfCoeffect _ = 0
