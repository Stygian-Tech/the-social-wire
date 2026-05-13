/**
 * MSW server setup for Node.js (Bun test runner).
 *
 * Import this in each test file that needs HTTP mocking:
 *   import { server } from "../mocks/server";
 *   beforeAll(() => server.listen());
 *   afterEach(() => server.resetHandlers());
 *   afterAll(() => server.close());
 */

import { setupServer } from "msw/node";
import { serviceHandlers } from "./handlers/service";

export const server = setupServer(...serviceHandlers);
