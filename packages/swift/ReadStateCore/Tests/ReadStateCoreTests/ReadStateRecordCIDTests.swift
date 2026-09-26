import Foundation
import Testing
@testable import ReadStateCore

@Test func recordCIDMatchesATProtoReferenceVectors() throws {
  // Generated independently with @atproto/lex-cbor cidForLex.
  let empty = #"{"$type":"app.thesocialwire.readState","version":1,"generation":"test","lastSequence":0}"#
  let cid = "bafyreiacxfcvmwagzgq5ssvwbtxlkkdt2n3puksrhj6llnpnxus6sg5eiq"
  try ReadStateRecordCID.verify(json: Data(empty.utf8), cid: cid)
  let linked = #"{"$type":"app.thesocialwire.readState","version":1,"generation":"test","lastSequence":1,"head":{"uri":"at://did:plc:viewer/app.thesocialwire.readStateChunk/a","cid":"bafyreiacxfcvmwagzgq5ssvwbtxlkkdt2n3puksrhj6llnpnxus6sg5eiq"}}"#
  try ReadStateRecordCID.verify(json: Data(linked.utf8),
    cid: "bafyreif57xwzt4hjfn3e4mpbn5zwbsgkcg53rdaxbkmhl2xync64l5rwva")
  #expect(throws: ReadStateError.invalidReference) {
    try ReadStateRecordCID.verify(json: Data(linked.utf8), cid: cid)
  }
  #expect(throws: ReadStateError.invalidRecord) {
    try ReadStateRecordCID.verify(json: Data(#"{"fraction":0.5}"#.utf8), cid: cid)
  }
}

@Test func recordCIDRetainsUnknownFieldsAndCanonicalScalarEncoding() throws {
  let json = #"{"$type":"app.thesocialwire.readStateChunk","version":1,"operations":[{"actionId":"test","sequence":24,"state":"unread","actedAt":"2026-09-08T00:00:00Z","selection":"exact","subjectUris":["x"]}],"extra":{"yes":true,"no":false,"missing":null,"negative":-32,"large":65536,"é":"unicode"}}"#
  try ReadStateRecordCID.verify(json: Data(json.utf8),
    cid: "bafyreiffzjj5lyxgn7rryry22fd7pcmmoyqimxdvyslo6egckwjq7l7ype")
}
