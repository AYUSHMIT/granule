{-# 
LANGUAGE 
  NoMonomorphismRestriction, 
  PackageImports, 
  TemplateHaskell, 
  FlexibleContexts 
#-}
module Repl.ReplParser where

import Prelude
--import Data.List
--import Data.Char 
import qualified Data.Text as T
import Text.Parsec 
import qualified Text.Parsec.Token as Token
import Text.Parsec.Language
--import Data.Functor.Identity
--import System.FilePath
--import System.Directory
import Syntax.Expr



lexer = haskellStyle {
    Token.reservedOpNames = [":", "let"]
}
tokenizer  = Token.makeTokenParser lexer
reservedOp = Token.reservedOp tokenizer
ws         = Token.whiteSpace tokenizer
symbol     = Token.symbol tokenizer    


data REPLExpr = 
      Let Id Expr Expr
    | ShowAST Expr
    | DumpState
    | Unfold Expr
    | Eval Expr
    | LoadFile String
    deriving Show
    
replTermCmdParser short long c p = do
    symbol ":"
    cmd <- many lower
    ws
    t <- p
    eof
    if (cmd == long || cmd == short)
    then return $ c t 
    else fail $ "Command \":"++cmd++"\" is unrecognized."
    
replIntCmdParser short long c = do
    symbol ":"
    cmd <- many lower
    eof
    if (cmd == long || cmd == short)
    then return c
    else fail $ "Command \":"++cmd++"\" is unrecognized."
    
replFileCmdParser short long c = do
    symbol ":"
    cmd <- many lower
    ws
    pathUntrimned <- many1 anyChar
    eof
    if(cmd == long || cmd == short)
    then do
        let path = T.unpack . T.strip . T.pack $ pathUntrimned
        return $ c path
    else fail $ "Command \":"++cmd++"\" is unrecognized."
    
    
-- showASTParser = replTermCmdParser "s" "show" ShowAST     

-- unfoldTermParser = replTermCmdParser "u" "unfold" Unfold 

dumpStateParser = replIntCmdParser "d" "dump" DumpState

loadFileParser = replFileCmdParser "l" "load" LoadFile


-- lineParser = 
          
lineParser = try dumpStateParser
          <|> try loadFileParser
          -- <|> try unfoldTermParser5
          -- <|> try showASTParser
          <?> "parse error"
          
parseLine :: String ->Either String REPLExpr
parseLine s = case (parse lineParser "" s) of
            Left msg -> Left $ show msg
            Right l -> Right l
            
                
                