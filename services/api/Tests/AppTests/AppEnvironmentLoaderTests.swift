import Foundation
import Testing

@testable import App

@Suite("AppEnvironmentLoader")
struct AppEnvironmentLoaderTests {

  @Test("parseDotenv reads KEY=value")
  func parseBasic() {
    let parsed = AppEnvironmentLoader.parseDotenv("FOO=bar\n")
    #expect(parsed["FOO"] == "bar")
  }

  @Test("parseDotenv ignores comments and blank lines")
  func parseComments() {
    let parsed = AppEnvironmentLoader.parseDotenv(
      """
       # comment
      BAZ=1

      QUUX=two
      """
    )
    #expect(parsed["BAZ"] == "1")
    #expect(parsed["QUUX"] == "two")
    #expect(parsed["# comment"] == nil)
  }

  @Test("parseDotenv supports export prefix and double quotes")
  func parseExportQuotes() {
    let parsed = AppEnvironmentLoader.parseDotenv(
      #"""
      export PORT="9000"
      NAME="say \"hi\""
      """#
    )
    #expect(parsed["PORT"] == "9000")
    #expect(parsed["NAME"] == #"say "hi""#)
  }

  @Test("parseDotenv supports single-quoted values")
  func parseSingleQuotes() {
    let parsed = AppEnvironmentLoader.parseDotenv("X='a b'")
    #expect(parsed["X"] == "a b")
  }

  @Test("mergeDotenvFile: process overrides file on duplicate keys")
  func mergeProcessWins() {
    let merged = AppEnvironmentLoader.mergeDotenvFile(
      [
        "PORT": "8080",
        "APP_ENV": "local",
      ],
      into: [
        "PORT": "9000",
      ]
    )
    #expect(merged["PORT"] == "9000")
    #expect(merged["APP_ENV"] == "local")
  }

  @Test("mergeDotenvFile: empty file map returns process unchanged")
  func mergeEmptyFile() {
    let proc = ["PORT": "7777"]
    let merged = AppEnvironmentLoader.mergeDotenvFile([:], into: proc)
    #expect(merged == proc)
  }

  @Test("mergeDotenvFile: carries over process-only keys")
  func mergeKeepsProcessOnly() {
    let merged = AppEnvironmentLoader.mergeDotenvFile(
      ["A": "from-file"],
      into: ["B": "from-process"]
    )
    #expect(merged["A"] == "from-file")
    #expect(merged["B"] == "from-process")
  }
}
