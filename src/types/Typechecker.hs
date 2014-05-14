module Typechecker(typecheckEncoreProgram) where

import Data.Maybe
import Data.List
import Control.Monad
import Control.Monad.Reader
import Control.Monad.Error

import AST
import PrettyPrinter
import Types
import Environment

newtype TCError = TCError (String, Backtrace)
instance Error TCError
instance Show TCError where
    show (TCError (msg, bt)) = 
        "*** Error during typechecking ***\n" ++
        msg ++ "\n" ++
        (concat $ map ((++"\n") . show) bt)

tcError s = do bt <- asks backtrace
               throwError $ TCError (s, bt)

typecheckEncoreProgram :: Program -> Either TCError ()
typecheckEncoreProgram p = runReader (runErrorT (typecheck p)) (buildClassTable p)

wfType :: Type -> ErrorT TCError (Reader Environment) ()
wfType ty = do refType <- asks $ classLookup ty
               unless (isPrimitive ty || isJust refType) $ tcError $ "Unknown type '" ++ show ty ++ "'"

class Checkable a where
    typecheck :: a -> ErrorT TCError (Reader Environment) ()

    pushTypecheck :: Pushable a => a -> ErrorT TCError (Reader Environment) ()
    pushTypecheck x = local (pushBT x) $ typecheck x

instance Checkable Program where
    typecheck (Program classes) = mapM_ pushTypecheck classes

instance Checkable ClassDecl where
    typecheck (Class cname fields methods) =
        do mapM_ pushTypecheck fields
           mapM_ typecheckMethod methods
           unless distinctFieldNames $ tcError $ "Duplicate field names"
           unless distinctMethodNames $ tcError $ "Duplicate method names"
        where
          typecheckMethod m = local (extendEnvironment [(Name "this", cname)]) $ pushTypecheck m
          distinctFieldNames = 
              nubBy (\f1 f2 -> (fname f1 == fname f2)) fields == fields
          distinctMethodNames = 
              nubBy (\m1 m2 -> (mname m1 == mname m2)) methods == methods

instance Checkable FieldDecl where
    typecheck (Field name ty) = wfType ty

instance Checkable MethodDecl where
     typecheck (Method name rtype params body) = 
         do wfType rtype
            mapM_ typecheckParam params
            local addParams $ pushHastype body rtype
         where
           typecheckParam = (\p@(Param(name, ty)) -> local (pushBT p) $ wfType ty)
           addParams = extendEnvironment (map (\(Param p) -> p) params)

class Typeable a where
    hastype :: a -> Type -> ErrorT TCError (Reader Environment) ()
    hastype a ty = do wfType ty
                      aType <- typeof a
                      unless (aType == ty) $ tcError $ "Type mismatch"

    typeof :: a -> ErrorT TCError (Reader Environment) Type
    typeof x = tcError "Typechecking not implemented for this syntactic construct"

    pushTypeof :: Pushable a => a -> ErrorT TCError (Reader Environment) Type
    pushTypeof x = local (pushBT x) $ typeof x

    pushHastype :: Pushable a => a -> Type -> ErrorT TCError (Reader Environment) ()
    pushHastype x ty = local (pushBT x) $ hastype x ty

instance Typeable Expr where
    hastype Null ty = 
        do wfType ty
           unless (not . isPrimitive $ ty) $ 
                  tcError $ "null cannot have primitive type '" ++ show ty ++ "'"
    hastype expr (Type "_NullType") = 
        do eType <- pushTypeof expr
           unless (not . isPrimitive $ eType) $ 
                  tcError $ "Primitive expression '" ++ show (ppExpr expr) ++ 
                            "' of type '" ++ show eType ++ "' cannot have null type"
    hastype expr ty = 
        do wfType ty
           eType <- pushTypeof expr
           unless (eType == ty) $ 
                  tcError $ "Type mismatch:\nExpression\n" ++ show (indent $ ppExpr expr) ++ 
                            "\nof type '" ++ show eType ++ "' does not have expected type '" ++
                            show ty ++ "'"

    typeof Skip = return $ Type "void"
    typeof (Call target name args) = 
        do targetType <- pushTypeof target
           when (isPrimitive targetType) $ 
                tcError $ "Cannot call method on expression '" ++ 
                          (show $ ppExpr target) ++ 
                          "' of primitive type '" ++ show targetType ++ "'"
           lookupResult <- asks $ methodLookup targetType name
           case lookupResult of
             Just (returnType, params) -> 
                 do unless (length args == length params) $ 
                       tcError $ "Method '" ++ show name ++ "' of class '" ++ show targetType ++
                                 "' expects " ++ show (length params) ++ " arguments. Got " ++ show (length args)
                    zipWithM_ (\arg (Param (_, ty)) -> pushHastype arg ty) args params
                    return returnType
             Nothing -> tcError $ "No method '" ++ show name ++ "' in class '" ++ show targetType ++ "'"
    typeof (Let x ty val expr) = 
        do varType <- pushTypeof val
           if varType == ty then
               local (extendEnvironment [(x, ty)]) $ pushTypeof expr
           else
               tcError $ "Declared type '" ++ show ty ++ "' does not match value type '" ++ show varType ++ "'"
    typeof (Seq exprs) = 
        do mapM_ (\expr -> pushTypeof expr) exprs 
           typeof (last exprs)
    typeof (IfThenElse cond thn els) = 
        do pushHastype cond (Type "bool")
           thnType <- pushTypeof thn
           elsType <- pushTypeof els
           unless (thnType == elsType) $ 
                  tcError $ "Type of then-branch (" ++ show thnType ++
                            ") does not match type of else-branch (" ++ show elsType ++ ")"
           return thnType
    typeof (While cond expr) = 
        do pushHastype cond (Type "bool")
           pushTypeof expr
    typeof (Get expr) = mzero
    typeof (FieldAccess expr f) = 
        do pathType <- pushTypeof expr
           when (isPrimitive pathType) $ 
                tcError $ "Cannot read field of expression '" ++ 
                          (show $ ppExpr expr) ++ "' of primitive type '" ++ show pathType ++ "'"
           fType <- asks $ fieldLookup pathType f
           case fType of
             Just ty -> return ty
             Nothing -> tcError $ "No field '" ++ show f ++ "' in class '" ++ show pathType ++ "'"
                                                         
    typeof (Assign lval expr) = 
        do lhType <- pushTypeof lval
           rhType <- pushTypeof expr
           unless (lhType == rhType) $ 
                  tcError $ "Incompatible assigment. \n" ++
                            "  Left hand side '" ++ show (ppLVal lval) ++ "' has type '" ++ show lhType ++ "'\n" ++
                            "  Right hand side '" ++ show (ppExpr expr) ++ "' has type '" ++ show rhType ++ "'\n"
           return $ Type "void"
    typeof (VarAccess x) = 
        do varType <- asks (varLookup x)
           case varType of
             Just ty -> return ty
             Nothing -> tcError $ "Unbound variable '" ++ show x ++ "'"
    typeof Null = return $ Type "_NullType"
    typeof BTrue = return $ Type "bool"
    typeof BFalse = return $ Type "bool"
    typeof (New ty) = 
        do wfType ty
           return ty
    typeof (Print ty expr) = 
        do hastype expr ty
           return $ Type "void"
    typeof (StringLiteral s) = return $ Type "string"
    typeof (IntLiteral n) = return $ Type "int"
    typeof (Binop op e1 e2) 
        | op `elem` cmpOps = 
            do hastype e1 (Type "int")
               hastype e2 (Type "int")
               return $ Type "bool"
        | op `elem` eqOps =
            do ty1 <- pushTypeof e1
               hastype e2 ty1
               return $ Type "bool"
        | op `elem` arithOps = 
            do hastype e1 (Type "int")
               hastype e2 (Type "int")
               return $ Type "int"
        | otherwise = tcError $ "Undefined binary operator '" ++ show op ++ "'"
        where
          cmpOps   = [AST.LT, AST.GT]
          eqOps    = [AST.EQ, AST.NEQ]
          arithOps = [AST.PLUS, AST.MINUS, AST.TIMES, AST.DIV]

instance Typeable LVal where
    typeof (LVal x) = 
        do varType <- asks (varLookup x)
           case varType of
             Just ty -> return ty
             Nothing -> tcError $ "Unbound variable '" ++ show x ++ "'"
    typeof (LField expr f) = 
        do pathType <- typeof expr
           fType <- asks $ fieldLookup pathType f
           when (isPrimitive pathType) $ 
                tcError $ "Cannot read field of expression '" ++ (show $ ppExpr expr) ++ 
                          "' of primitive type '" ++ show pathType ++ "'"
           case fType of
             Just ty -> return ty
             Nothing -> tcError $ "No field '" ++ show f ++ "' in class '" ++ show pathType ++ "'"