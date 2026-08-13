class_name NativeParityGuard

# What a parity suite does when its kernel is absent.
#
# The availability check itself stays in each suite — they differ meaningfully
# (a ClassDB lookup, a constructed handle, a subsystem's own `native_available`)
# and a handle that exists but failed `configure` is not the same fact as a class
# that never registered. Only the RESPONSE is shared, because it is the response
# that was wrong everywhere at once.
#
# Skipping is right on a dev machine: `native/bin/` is gitignored, so a fresh
# clone has no binary and the suites have nothing to compare against. It is wrong
# in CI, where the extension is built before GUT (`.github/workflows/test.yml`) —
# there, an absent kernel means the build or the class registration broke, and
# reporting that as a skip paints the run green while the parity gate does not
# run at all. That is not hypothetical: it is how `NativePuckStep` drifted two
# commits from its GDScript reference and reached `main` (#678/#679) with a
# seeded test that reproduces the divergence exactly, sitting pending on every CI
# run for as long as the kernels had existed.
#
# So CI sets MITTS_REQUIRE_NATIVE=1 and the same skip becomes a failure.

const REQUIRE_ENV: String = "MITTS_REQUIRE_NATIVE"


static func native_required() -> bool:
	return OS.get_environment(REQUIRE_ENV) == "1"


# Call from a suite's own `_native_missing()` once it has established the kernel
# is unavailable. Marks the test pending (dev) or failed (CI), never both.
static func report_missing(test: GutTest, kernel: String) -> void:
	if native_required():
		test.fail_test(
				("%s is not available, but %s=1 requires it — the GDExtension "
				+ "build or the class registration failed, so the parity gate "
				+ "did not run. See native/README.md.") % [kernel, REQUIRE_ENV])
		return
	test.pending("native extension not built — see native/README.md")
