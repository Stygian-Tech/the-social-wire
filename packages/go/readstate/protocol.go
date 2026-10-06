// Package readstate exposes the repository-local protocol shared with the
// TypeScript read-state implementation. Platform storage is supplied by clients.
package readstate

import "github.com/stygian-tech/the-social-wire/packages/go/readstatecore"

type Operation = readstatecore.Operation
type Projection = readstatecore.Projection
type Manifest = readstatecore.Manifest
type Chunk = readstatecore.Chunk
type Reference = readstatecore.Reference
type DeviceReceipt = readstatecore.DeviceReceipt

var NewProjection = readstatecore.NewProjection
var ValidateManifest = readstatecore.ValidateManifest
var ValidateChunk = readstatecore.ValidateChunk
var ValidateOperation = readstatecore.ValidateOperation
var NewDeviceReceipt = readstatecore.NewDeviceReceipt
