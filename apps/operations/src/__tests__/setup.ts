import { expect } from "bun:test"
import * as matchers from "@testing-library/jest-dom/matchers"
import { JSDOM } from "jsdom"

if (!process.env.NEXT_PUBLIC_APP_ENV && !process.env.APP_ENV) process.env.APP_ENV = "dev"

if (typeof document === "undefined") {
  const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost" })
  globalThis.window = dom.window as unknown as Window & typeof globalThis
  globalThis.document = dom.window.document
  globalThis.navigator = dom.window.navigator
  globalThis.Element = dom.window.Element
  globalThis.HTMLElement = dom.window.HTMLElement
  globalThis.Node = dom.window.Node
  globalThis.Event = dom.window.Event
  globalThis.MouseEvent = dom.window.MouseEvent
  globalThis.getComputedStyle = dom.window.getComputedStyle.bind(dom.window)
  globalThis.requestAnimationFrame = (callback) => setTimeout(() => callback(Date.now()), 0) as unknown as number
  globalThis.cancelAnimationFrame = (handle) => clearTimeout(handle)
}

expect.extend(matchers)
