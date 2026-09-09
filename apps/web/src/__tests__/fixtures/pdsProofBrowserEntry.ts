import { verifyReadStateCAR } from "../../lib/pdsReadStateProof";
(globalThis as unknown as { verifyReadStateCAR: typeof verifyReadStateCAR }).verifyReadStateCAR = verifyReadStateCAR;
