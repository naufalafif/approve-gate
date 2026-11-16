import { bindings, defineConfig, exports } from "cf/config";

import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
	worker: {
		name: "approve-gate-relay",
		compatibilityDate: "2026-10-01",
		entrypoint,
		exports: {
			Topic: exports.durableObject({ storage: "sqlite" }),
		},
		env: {
			TOPICS: bindings.durableObject({
				worker: "approve-gate-relay",
				exportName: "Topic",
			}),
		},
	},
});
