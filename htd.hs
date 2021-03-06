-----------------------------------------------------------------------------
-- |
-- Copyright   :  Copyright (c) 2010 Chris Pettitt
-- License     :  MIT
-- Maintainer  :  cpettitt@gmail.com
--
-- A simple utility for managing tasks.
--
-----------------------------------------------------------------------------

module Main (main) where

import Control.Monad (unless)
import Control.Monad.Trans (liftIO)
import Control.Exception (catch)
import qualified Control.Exception as E
import Control.Parallel.Strategies (rdeepseq)

import Data.List (foldl', isPrefixOf)
import Data.Maybe (fromJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Time.Clock (getCurrentTime, utctDay)
import Data.Time.Calendar (toGregorian)

import System.Console.ANSI (Color(..)
                           , ColorIntensity(..)
                           , ConsoleLayer(..)
                           , SGR(..)
                           , Underlining(..)
                           , clearScreen
                           , setCursorPosition
                           , setSGRCode
                           )

import System.Console.Haskeline (InputT
                                , defaultSettings
                                , getInputLine
                                , runInputT
                                , setComplete
                                )
import System.Console.Haskeline.Completion (CompletionFunc, simpleCompletion)
import System.Directory (copyFile
                        , createDirectoryIfMissing
                        , doesFileExist
                        , getAppUserDataDirectory
                        )
import System.Environment (getArgs)
import System.IO (IOMode(..), hGetContents, hPutStr, withFile)

import Text.Printf (printf)

{-------------------------------------------------------------------------------
  Types
-------------------------------------------------------------------------------}

type Id = Int
type Todo = String
type Tag = String
type TodoDB = [Todo]
type CmdHandler = [String] -> IO ()
type CmdInfo = (String, CmdHandler, String, String)
type TagFilter = (Set Tag, Set Tag)

{-------------------------------------------------------------------------------
  Main
-------------------------------------------------------------------------------}

main :: IO ()
main = do
        args <- getArgs

        if null args
            then do
                putStrLn "Haskell Todo (HTD) - Interactive Mode"
                runInputT haskelineSettings interactive
            else dispatch args
    where
        haskelineSettings = setComplete autoComplete defaultSettings

{-------------------------------------------------------------------------------
  Interactive Loop
-------------------------------------------------------------------------------}

interactive :: InputT IO ()
interactive = do
    line <- getInputLine "> "
    case line of
        Nothing -> return ()
        Just "quit" -> return ()
        Just "clear" -> liftIO resetScreen >> interactive
        Just input -> liftIO (dispatch (words input)) >> interactive

{-------------------------------------------------------------------------------
  Commands
-------------------------------------------------------------------------------}

dispatch :: [String] -> IO ()
dispatch [] = return ()
dispatch (cmd:args) = case lookupCmd cmd of
        Nothing        -> printError $ "Unknown command: " ++ unwords (cmd:args)
        Just (_,f,_,_) -> f args

cmds :: [CmdInfo]
cmds =
    [("add",        cmdAdd,      "<description>",         "adds a task")
    ,("change",     cmdChange,   "<id> <description>",    "changes a task")
    ,("rm",         cmdRm,       "<id>",                  "removes a task")
    ,("after",      cmdAfter,    "<id> <id>",             "moves a task after another task")
    ,("before",     cmdBefore,   "<id> <id>",             "moves a task before another task")
    ,("addtag",     cmdAddTag,   "<id> <tag>",            "adds a tag to a task")
    ,("rmtag",      cmdRmTag,    "<id> <tag>",            "removes a tag from a task")
    ,("done",       cmdDone,     "<id>",                  "marks a task as done")
    ,("undone",     cmdUndone,   "<id>",                  "resets the done state for a task")
    ,("projects",   cmdProjects, "",                      "list the project names")
    ,("contexts",   cmdContexts, "",                      "list the context names")
    ,("list",       cmdList,     "[tag | -tag ...]",      "list all tasks with optional filtering")
    ,("help",       cmdHelp,      "",                     "this help information")
    ]

cmdAdd :: CmdHandler
cmdAdd []   = printUsage "add"
cmdAdd desc = modifyDB (add $ unwords desc)

cmdChange :: CmdHandler
cmdChange (idStr:desc)
    | not (null desc) = modifyDB (adjustTodo (read idStr) (const $ unwords desc))
cmdChange _ = printUsage "change"

cmdRm :: CmdHandler
cmdRm (idStr:[]) = modifyDB (delete $ read idStr)
cmdRm _ = printUsage "rm"

cmdAfter :: CmdHandler
cmdAfter [idStr1,idStr2] = modifyDB (after (read idStr1) (read idStr2))
cmdAfter _ = printUsage "after"

cmdBefore :: CmdHandler
cmdBefore [idStr1,idStr2] = modifyDB (before (read idStr1) (read idStr2))
cmdBefore _ = printUsage "before"

cmdAddTag :: CmdHandler
cmdAddTag (idStr:tag:[]) = modifyDB (adjustTodo (read idStr) (addTag tag))
cmdAddTag _ = printUsage "addtag"

cmdRmTag :: CmdHandler
cmdRmTag (idStr:tag:[]) = modifyDB (adjustTodo (read idStr) (deleteTag tag))
cmdRmTag _ = printUsage "rmtag"

cmdDone :: CmdHandler
cmdDone (idStr:[]) = do
    date <- dateStr
    modifyDB (adjustTodo (read idStr) (addTag $ "@done{" ++ date ++ "}"))
cmdDone _ = printUsage "done"

cmdUndone :: CmdHandler
cmdUndone (idStr:[]) = modifyDB (adjustTodo (read idStr) (deleteTag "@done"))
cmdUndone _ = printUsage "undone"

cmdProjects :: CmdHandler
cmdProjects [] = withDB (unlines . map colorize . Set.toList . filterTags isProject) >>= putStr
cmdProjects _ = printUsage "projects"

cmdContexts :: CmdHandler
cmdContexts [] = withDB (unlines . map colorize . Set.toList .  filterTags isContext) >>= putStr
cmdContexts _ = printUsage "contexts"

cmdList :: CmdHandler
cmdList tags = withDB (list tagFilter) >>= putStr
    where
        defaultFilter = ["-@done"]
        tagFilter = foldl' updateFilter (Set.empty, Set.empty) (defaultFilter ++ tags)
        updateFilter (sel, desel) ('-':tag) = (Set.delete tag sel, Set.insert tag desel)
        updateFilter (sel, desel) ('+':tag) = (sel, Set.delete tag desel)
        updateFilter (sel, desel) tag       = (Set.insert tag sel, Set.delete tag desel)

cmdHelp :: CmdHandler
cmdHelp _ = do
        putStrLn "Haskell Todo (HTD) Commands:"
        putStr . unlines . map printCmdInfo $ cmds

{-------------------------------------------------------------------------------
  TodoDB - Monadic Operations
-------------------------------------------------------------------------------}

load :: IO TodoDB
load = do
    dbFile <- getDBFileName
    maybeCreateDB
    withFile dbFile ReadMode $ \h -> do
        c <- hGetContents h
        rdeepseq c `seq` return $! lines c

save :: TodoDB -> IO ()
save db = do
    dbFile <- getDBFileName
    result <- doesFileExist dbFile
    case result of
      False ->  writeFile dbFile ""
      True ->  backupDB
    withFile dbFile WriteMode $ \h -> hPutStr h $ unlines db

withDB :: (TodoDB -> a) -> IO a
withDB f = fmap f load

modifyDB :: (TodoDB -> TodoDB) -> IO ()
modifyDB f = catch doModify handleError
    where
      doModify = do
        db' <- withDB f
        db' `seq` save db'
      handleError :: E.SomeException -> IO ()
      handleError e = print e >> return ()

{-------------------------------------------------------------------------------
  TodoDB - Pure Manipulation
-------------------------------------------------------------------------------}

empty :: TodoDB
empty = []

add :: String -> TodoDB -> TodoDB
add todo db = db ++ [todo]

adjustTodo :: Id -> (Todo -> Todo) -> TodoDB -> TodoDB
adjustTodo todoId f db
    | todoId > 0 && todoId <= length db =
        take (todoId - 1) db ++ [f (db !! (todoId - 1))] ++ drop todoId db
    | otherwise = db

addTag :: Tag -> Todo -> Todo
addTag tag = (tag ++) . (" " ++)

deleteTag :: Tag -> Todo -> Todo
deleteTag tag = unwords . filter ((/= tag) . stripTagMeta) . words

list :: TagFilter -> TodoDB -> String
list (selTags, deselTags) db = unlines $ map (uncurry fmtTodo) todos'
    where todos' = filter (filterRule . snd) (todosWithIds db)
          filterRule todo = hasTags selTags todo && noHasTags deselTags todo

after :: Id -> Id -> TodoDB-> TodoDB
after x y as = insert idx a . delete x $ as
    where
        idx
            | x > y = y + 1
            | otherwise = y
        a = as !! (x - 1)

before :: Id -> Id -> TodoDB -> TodoDB
before x y as = insert idx a . delete x $ as
    where
        idx
            | x < y = y - 1
            | otherwise = y
        a = as !! (x - 1)

delete :: Id -> TodoDB -> TodoDB
delete x as = take (x - 1) as ++ drop x as

insert :: Id -> Todo -> TodoDB -> TodoDB
insert x a as = take (x - 1) as ++ [a] ++ drop (x - 1) as

{-------------------------------------------------------------------------------
  Color Handling
-------------------------------------------------------------------------------}

colorize :: String -> String
colorize x
    | isContext x = applyColor contextColor x
    | isProject x = applyColor projectColor x
    | otherwise   = x


applyColor :: [SGR] -> String -> String
applyColor sgr str = printf "%s%s%s" (setSGRCode sgr) str (setSGRCode resetColor)

-- Color codes
idColor :: [SGR]
idColor      = [SetColor Foreground Vivid Magenta]

resetColor :: [SGR]
resetColor   = []

contextColor :: [SGR]
contextColor = [SetColor Foreground Vivid Green, SetUnderlining SingleUnderline]

projectColor :: [SGR]
projectColor = [SetColor Foreground Vivid Blue, SetUnderlining SingleUnderline]

{-------------------------------------------------------------------------------
  Auto Completion
-------------------------------------------------------------------------------}

autoComplete :: CompletionFunc IO
autoComplete (leftStr, _)
        | length (words leftStr) > 1 = return ("", [])
        | otherwise = return ("", completions)
    where
        word = reverse leftStr
        completions  = map simpleCompletion $ filter (word `isPrefixOf`) cmdNames
        cmdNames = map cmdInfoToName cmds
        cmdInfoToName (name,_,_,_) = name

{-------------------------------------------------------------------------------
  Misc Helpers
-------------------------------------------------------------------------------}

maybeCreateDB :: IO ()
maybeCreateDB = do
    appDir <- getAppDir
    createDirectoryIfMissing False appDir
    dbExists <- getDBFileName >>= doesFileExist
    unless dbExists (save empty) 

backupDB :: IO ()
backupDB = do
    dbFile <- getDBFileName
    backupFile <- fmap (++ "/.todo.bak") getAppDir
    copyFile dbFile backupFile

getDBFileName :: IO String
getDBFileName = do
    appDir <- getAppDir
    return $ appDir ++ "/todo"

getAppDir :: IO String
getAppDir = getAppUserDataDirectory "htd"

fmtTodo :: Id -> Todo -> String
fmtTodo todoId todo = printf "%s %s" idColored todoColored
    where
        idColored = applyColor idColor $ printf "[%4s]" (show todoId)
        todoColored  = unwords . map colorize . words $ todo

-- Returns @True@ if the 'Todo' has all specified 'Tag's.
hasTags :: Set Tag -> Todo -> Bool
hasTags tags todo = tags `Set.isSubsetOf` getTags todo

-- Returns @True@ if the 'Todo' has none of the specified 'Tag's.
noHasTags :: Set Tag -> Todo -> Bool
noHasTags tags todo = Set.null (tags `Set.intersection` getTags todo)

getTags :: Todo -> Set Tag
getTags = Set.fromList . map stripTagMeta . filter isTag . words

stripTagMeta :: Tag -> Tag
stripTagMeta = takeWhile (/= '{')

isContext :: String -> Bool
isContext [] = False
isContext x  = head x == '@'

isProject :: String -> Bool
isProject [] = False
isProject x  = head x == ':'

isTag :: String -> Bool
isTag x  = isContext x || isProject x

filterTags :: (Tag -> Bool) -> TodoDB -> Set Tag
filterTags f = Set.fromList . map stripTagMeta . filter f . words . unlines

todosWithIds :: TodoDB -> [(Id, Todo)]
todosWithIds = zip [1..]

dateStr :: IO String
dateStr = do
    currentTime <- getCurrentTime
    let (year, month, day) = toGregorian $ utctDay currentTime
    return $ printf "%d-%d-%d" year month day

printError :: String -> IO ()
printError x = do
    putStrLn x
    putStrLn "Use 'help' for usage information."

printUsage :: String -> IO ()
printUsage = putStrLn . ("Usage: " ++) . printCmdInfo . fromJust . lookupCmd

lookupCmd :: String -> Maybe CmdInfo
lookupCmd cmd = lookup cmd $ map cmdInfoMap cmds
    where
        cmdInfoMap (name,handler,args,desc) = (name, (name, handler, args, desc))

printCmdInfo :: CmdInfo -> String
printCmdInfo (name, _, args, desc) = printf "%-10s %-20s %s" name args desc

resetScreen :: IO ()
resetScreen = clearScreen >> setCursorPosition 0 0
