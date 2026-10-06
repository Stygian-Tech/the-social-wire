// Package readstate exposes the repository-local protocol shared with the
// TypeScript read-state implementation. Platform storage is supplied by clients.
package readstate

// Re-exports the implemented ReadStateCore protocol surfaces using aliases, preserving
// type identity across imports. This facade provides no repository, outbox, persistence,
// sync, or garbage collector.

import "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"

// Operation aliases the implemented readstatecore type, preserving a single shared
// protocol representation.
type Operation = readstatecore.Operation

// Projection aliases the implemented readstatecore type, preserving a single shared
// protocol representation.
type Projection = readstatecore.Projection

// Manifest aliases the implemented readstatecore type, preserving a single shared protocol
// representation.
type Manifest = readstatecore.Manifest

// Chunk aliases the implemented readstatecore type, preserving a single shared protocol
// representation.
type Chunk = readstatecore.Chunk

// Reference aliases the implemented readstatecore type, preserving a single shared
// protocol representation.
type Reference = readstatecore.Reference

// DeviceReceipt aliases the implemented readstatecore type, preserving a single shared
// protocol representation.
type DeviceReceipt = readstatecore.DeviceReceipt

// NewProjection exposes the implemented readstatecore contract through this facade.
var NewProjection = readstatecore.NewProjection

// ValidateManifest exposes the implemented readstatecore contract through this facade.
var ValidateManifest = readstatecore.ValidateManifest

// ValidateChunk exposes the implemented readstatecore contract through this facade.
var ValidateChunk = readstatecore.ValidateChunk

// ValidateOperation exposes the implemented readstatecore contract through this facade.
var ValidateOperation = readstatecore.ValidateOperation

// NewDeviceReceipt exposes the implemented readstatecore contract through this facade.
var NewDeviceReceipt = readstatecore.NewDeviceReceipt
