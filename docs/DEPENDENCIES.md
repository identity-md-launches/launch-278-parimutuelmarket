# Vendored dependency provenance

All dependencies are checked-in ordinary Solidity files; there are no submodules or install-time downloads. Upstream sources are unmodified. Only the transitive OpenZeppelin source dependencies of ERC20, SafeERC20, Math, and ReentrancyGuard are included; forge-std's `src/` is included for standalone test and protected-harness compatibility. License files accompany both packages.

| Package | Pinned upstream release | Source archive SHA-256 |
| --- | --- | --- |
| OpenZeppelin Contracts | `v5.2.0`, `https://github.com/OpenZeppelin/openzeppelin-contracts` | `80f86d2dba4e1c0d66a216d2ddf0ac5d731edf9338ea12a985edca8774802814` |
| forge-std | `v1.9.7`, `https://github.com/foundry-rs/forge-std` | `45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94` |

Archive download URLs were respectively `https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.2.0` and `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`. The hashes document the exact downloaded release archives, not hashes of the vendored subsets. Compiler binaries are not delivered; the checking environment supplies the pinned compiler.
