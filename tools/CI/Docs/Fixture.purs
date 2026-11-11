module CI.Docs.Fixture (main) where

import Prelude

import Data.Array as Data.Array
import Effect as Effect
import Effect.Exception as Effect.Exception
import Node.Process as Node.Process
import Platform.Node.Build as Platform.Node.Build

main :: Effect.Effect Unit
main = do
  args <- Data.Array.drop 2 <$> Node.Process.argv
  case args of
    [ "failure" ] ->
      Effect.Exception.throw "Deliberate generator failure"
    [ "missing" ] ->
      pure unit
    [ "empty" ] ->
      Platform.Node.Build.mkdirImpl ".out/docs"
    [ mode ] -> do
      Platform.Node.Build.mkdirImpl ".out/docs"
      Platform.Node.Build.writeImpl ".out/docs/index.html"
        (if mode == "invalid" then "not HTML" else if mode == "empty-index" then "<html><body>   </body></html>" else "<!doctype html><html><body>Current TEST developer journey</body></html>")
      when (mode == "link") (Platform.Node.Build.executeImpl "ln" [ "-s", "/etc/passwd", ".out/docs/unsafe" ] ".")
      when (mode == "hardlink") (Platform.Node.Build.executeImpl "ln" [ ".out/docs/index.html", ".out/docs/duplicate.html" ] ".")
      when (mode == "special") (Platform.Node.Build.executeImpl "mkfifo" [ ".out/docs/unsafe" ] ".")
    _ ->
      Effect.Exception.throw "Expected fixture mode"
