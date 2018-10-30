{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
module Pact.Analyze.Eval.Core where

import           Control.Lens                (over)
import           Data.Foldable               (foldrM)
import qualified Data.Map.Strict             as Map
import           Data.SBV                    (Boolean (bnot, (&&&), (|||)),
                                              EqSymbolic ((./=), (.==)),
                                              OrdSymbolic ((.<), (.<=), (.>), (.>=)),
                                              SymWord, ite, bAll, true, false)
import qualified Data.SBV.String             as SBVS
-- import qualified Data.SBV.List               as SBVL
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import Data.Type.Equality

import           Pact.Analyze.Errors
import           Pact.Analyze.Eval.Numerical
import           Pact.Analyze.Types
import           Pact.Analyze.Types.Eval
import           Pact.Analyze.Util


-- Note [Time Representation]
--
-- Pact uses the Thyme library (UTCTime) to represent times. Thyme internally
-- uses a 64-bit count of microseconds since the MJD epoch. So, our symbolic
-- representation is naturally a 64-bit integer.
--
-- The effect from a Pact-user's point of view is that we store 6 digits to
-- the right of the decimal point in times (even though we don't print
-- sub-second precision by default...).
--
-- pact> (add-time (time "2016-07-23T13:30:45Z") 0.001002)
-- "2016-07-23T13:30:45Z"
-- pact> (= (add-time (time "2016-07-23T13:30:45Z") 0.001002)
--          (add-time (time "2016-07-23T13:30:45Z") 0.0010021))
-- true
-- pact> (= (add-time (time "2016-07-23T13:30:45Z") 0.001002)
--          (add-time (time "2016-07-23T13:30:45Z") 0.001003))
-- false

evalIntAddTime
  :: Analyzer m
  => TermOf m 'TyTime
  -> TermOf m 'TyInteger
  -> m (S Time)
evalIntAddTime timeT secsT = do
  time <- eval timeT
  secs <- eval secsT
  -- Convert seconds to milliseconds /before/ conversion to Integer (see note
  -- [Time Representation]).
  pure $ time + fromIntegralS (secs * 1000000)

evalDecAddTime
  :: Analyzer m
  => TermOf m 'TyTime
  -> TermOf m 'TyDecimal
  -> m (S Time)
evalDecAddTime timeT secsT = do
  time <- eval timeT
  secs <- eval secsT
  if isConcreteS secs
  -- Convert seconds to milliseconds /before/ conversion to Integer (see note
  -- [Time Representation]).
  then pure $ time + fromIntegralS (banker'sMethodS (secs * fromInteger' 1000000))
  else throwErrorNoLoc $ PossibleRoundoff
    "A time being added is not concrete, so we can't guarantee that roundoff won't happen when it's converted to an integer."

evalComparisonOp
  :: ( Analyzer m
     , a' ~ Concrete a
     , SymWord a', Show a')
  => ComparisonOp
  -> TermOf m a
  -> TermOf m a
  -> m (S Bool)
evalComparisonOp op xT yT = do
  x <- eval xT
  y <- eval yT
  pure $ sansProv $ case op of
    Gt  -> x .> y
    Lt  -> x .< y
    Gte -> x .>= y
    Lte -> x .<= y
    Eq  -> x .== y
    Neq -> x ./= y

evalLogicalOp'
  :: ( Analyzer m
     , a' ~ Concrete a
     , Boolean (S a'), Show a', SymWord a')
  => LogicalOp
  -> [TermOf m a]
  -> m (S a')
evalLogicalOp' op terms = do
  symBools <- traverse eval terms
  case (op, symBools) of
    (AndOp, [a, b]) -> pure $ a &&& b
    (OrOp,  [a, b]) -> pure $ a ||| b
    (NotOp, [a])    -> pure $ bnot a
    _               -> throwErrorNoLoc $ MalformedLogicalOpExec op $ length terms

evalEqNeq
  :: ( Analyzer m
     , a' ~ Concrete a
     , SymWord a', Show a')
  => EqNeq
  -> TermOf m a
  -> TermOf m a
  -> m (S Bool)
evalEqNeq op xT yT = do
  x <- eval xT
  y <- eval yT
  pure $ sansProv $ case op of
    Eq'  -> x .== y
    Neq' -> x ./= y

evalObjectEqNeq
  :: Analyzer m
  => EqNeq
  -> TermOf m 'TyObject
  -> TermOf m 'TyObject
  -> m (S Bool)
evalObjectEqNeq op xT yT = do
  x <- evalO xT
  y <- evalO yT
  pure $ sansProv $ case op of
    Eq'  -> x .== y
    Neq' -> x ./= y

evalCore
  :: ( Analyzer m
     , a' ~ Concrete a
     , SymWord a', Show (Core (TermOf m) a))
  => Core (TermOf m) a -> m (S a')
evalCore (Lit a)                           = pure (literalS a)
evalCore (Sym s)                           = pure s
evalCore (StrConcat p1 p2)                 = (.++) <$> eval p1 <*> eval p2
evalCore (StrLength p)
  = over s2Sbv SBVS.length . coerceS @Str @String <$> eval p
evalCore (Numerical a)                     = evalNumerical a
evalCore (IntAddTime time secs)            = evalIntAddTime time secs
evalCore (DecAddTime time secs)            = evalDecAddTime time secs
evalCore (IntegerComparison op x y)        = evalComparisonOp op x y
evalCore (DecimalComparison op x y)        = evalComparisonOp op x y
evalCore (TimeComparison op x y)           = evalComparisonOp op x y
evalCore (StringComparison op x y)         = evalComparisonOp op x y
evalCore (BoolComparison op x y)           = evalComparisonOp op x y
evalCore (ObjectEqNeq op x y)              = evalObjectEqNeq  op x y
evalCore (KeySetEqNeq      op x y)         = evalEqNeq        op x y
evalCore (Logical op props)                = evalLogicalOp op props
evalCore (ObjAt schema colNameT objT retType)
  = evalObjAt schema colNameT objT retType
evalCore (ObjectMerge _ _)                 =
  error "object merge can not produce a simple value"
evalCore LiteralObject {}                  =
  error "literal object can't be an argument to evalCore"
-- evalCore (StringContains needle haystack) = do
--   needle'   <- eval needle
--   haystack' <- eval haystack
--   pure $ sansProv $ _sSbv needle' `SBVS.isInfixOf` _sSbv haystack'
evalCore (ListEqNeq op (EList tyA a) (EList tyB b)) = case tyA of
  SList tyA' -> case singEq tyA tyB of
    Nothing   -> error "TODO"
    Just Refl -> withEq tyA' $ withSymWord tyA' $ withShow tyA' $ do
      a' <- evalL a
      b' <- evalL b
      pure $ case pair a' b' of
        Nothing -> case op of
          Eq'  -> false
          Neq' -> true
        Just pairs -> sansProv $ flip bAll pairs $ uncurry $ case op of
          Eq'  -> (.==)
          Neq' -> (./=)
evalCore (Var vid name) = do
  mVal <- getVar vid
  case mVal of
    Nothing                -> throwErrorNoLoc $ VarNotInScope name vid
    Just (AVal mProv sval) -> pure $ mkS mProv sval
    Just (AnObj obj)       -> throwErrorNoLoc $ AValUnexpectedlyObj obj
    Just OpaqueVal         -> throwErrorNoLoc OpaqueValEncountered
evalCore x = error $ "no case for: " ++ show x

evalCoreL
  :: ( Analyzer m
     , a' ~ Concrete a
     , SymWord a', Show a')
  => Core (TermOf m) ('TyList a) -> m ([S a'])
evalCoreL (LiteralList _ty xs) = do
  vals <- traverse (fmap _sSbv . eval) xs
  pure $ sansProv <$> vals
  -- pure $ SList (fromIntegral (length xs)) vals
  -- sansProv . SBVL.implode <$> traverse (fmap _sSbv . eval) xs
-- evalCoreL (ListDrop n list) = do
--   n'    <- eval n
--   list' <- eval list
--   pure $ sansProv $ _sSbv n' `SBVL.drop` _sSbv list'
-- evalCoreL ListReverse{} = undefined
-- evalCoreL ListSort{} = undefined
-- evalCoreL (ListTake n list) = do
--   n'    <- eval n
--   list' <- eval list
--   pure $ sansProv $ _sSbv n' `SBVL.take` _sSbv list'

evalObjAt
  :: (Analyzer m, SymWord a)
  => Schema
  -> TermOf m 'TyStr
  -> TermOf m 'TyObject
  -> EType
  -> m (S a)
evalObjAt schema@(Schema schemaFields) colNameT objT retType = do
  obj@(Object fields) <- evalO objT

  -- Filter down to only fields which contain the type we're looking for
  let relevantFields
        = map fst
        $ filter (\(_name, ty) -> ty == retType)
        $ Map.toList schemaFields

  colName :: S Str <- eval colNameT

  firstName:relevantFields' <- case relevantFields of
    [] -> throwErrorNoLoc $ AtHasNoRelevantFields retType schema
    _  -> pure relevantFields

  let getObjVal fieldName = case Map.lookup fieldName fields of
        Nothing -> throwErrorNoLoc $ KeyNotPresent fieldName obj

        Just (_fieldType, AVal mProv sval) -> pure $ mkS mProv sval

        Just (fieldType, AnObj _subObj) -> throwErrorNoLoc $
          ObjFieldOfWrongType fieldName fieldType

        Just (_fieldType, OpaqueVal) -> throwErrorNoLoc OpaqueValEncountered

  firstVal <- getObjVal firstName

  -- Fold over each relevant field, building a sequence of `ite`s. We require
  -- at least one matching field, ie firstVal. At first glance, this should
  -- just be a `foldr1M`, but we want the type of accumulator and element to
  -- differ, because elements are `String` `fieldName`s, while the accumulator
  -- is an `SBV a`.
  foldrM
    (\fieldName rest -> do
      val <- getObjVal fieldName
      pure $ ite (colName .== literalS (Str (T.unpack fieldName))) val rest
    )
    firstVal
    relevantFields'

evalObjAtO
  :: forall m
   . Analyzer m
  => TermOf m 'TyStr
  -> TermOf m 'TyObject
  -> m Object
evalObjAtO colNameT objT = do
    obj@(Object fields) <- evalO objT
    sCn <- eval colNameT

    let getObjVal :: Text -> m Object
        getObjVal fieldName = case Map.lookup fieldName fields of
          Nothing -> throwErrorNoLoc $ KeyNotPresent fieldName obj
          Just (fieldType, AVal _ _) -> throwErrorNoLoc $
            ObjFieldOfWrongType fieldName fieldType
          Just (_fieldType, AnObj subObj) -> pure subObj
          Just (_fieldType, OpaqueVal) -> throwErrorNoLoc OpaqueValEncountered

    case unliteralS (coerceS @Str @String sCn) of
      Nothing -> throwErrorNoLoc "Unable to determine statically the key used in an object access evaluating to an object (this is an object in an object)"
      Just concreteColName -> getObjVal (T.pack concreteColName)

evalCoreO
  :: Analyzer m
  => Core (TermOf m) 'TyObject -> m Object
evalCoreO (LiteralObject obj) = Object <$> traverse evalExistential obj
evalCoreO (ObjAt _schema colNameT objT _retType) = evalObjAtO colNameT objT
evalCoreO (ObjectMerge objT1 objT2) = mappend <$> evalO objT1 <*> evalO objT2
evalCoreO (Var vid name) = do
  mVal <- getVar vid
  case mVal of
    Nothing            -> throwErrorNoLoc $ VarNotInScope name vid
    Just (AVal _ val') -> throwErrorNoLoc $ AValUnexpectedlySVal val'
    Just (AnObj obj)   -> pure obj
    Just OpaqueVal     -> throwErrorNoLoc OpaqueValEncountered

-- TODO(joel): I don't think an object can appear hear. Get more clarity on
-- this.
evalCoreO (Lit obj)     = pure obj
evalCoreO (Sym _)       = vacuousMatch "an object cannot be a symbolic value"
evalCoreO (Numerical _) = vacuousMatch "an object cannot be a numerical value"


evalExistential :: Analyzer m => Existential (TermOf m) -> m (EType, AVal)
evalExistential = \case
  ESimple ty prop -> withShow ty $ withSymWord ty $ do
    prop' <- eval prop
    pure (EType ty, mkAVal prop')
  EList (SList ty) prop -> withShow ty $ withSymWord ty $ do
    vals  <- evalL prop
    pure (EType ty, mkAList vals)
  EObject ty prop -> do
    prop' <- evalO prop
    pure (EObjectTy ty, AnObj prop')
