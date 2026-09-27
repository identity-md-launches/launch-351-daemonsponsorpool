# Vendored dependencies

The following sources are included as ordinary files and are sufficient for offline compilation. There are no git submodules or runtime package downloads. Upstream files are unmodified.

| Library | Pinned upstream release | Included files | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | [v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) | ERC20, IERC20, IERC20Metadata, IERC20Permit, SafeERC20, Address, Context, ReentrancyGuard, draft-IERC6093 and their license | `lib/openzeppelin-contracts/LICENSE` (MIT) |
| Forge Standard Library | [v1.9.4](https://github.com/foundry-rs/forge-std/tree/v1.9.4) | Complete `src/` and licenses; test-only dependency | `lib/forge-std/LICENSE-MIT`, `lib/forge-std/LICENSE-APACHE` |

Downloaded archive SHA-256 digests:

```text
https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2
18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a

https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.4
9bf191808ba79584a69ee4f288bfb9f217d1187c43d46f59780d86cab9196a15
```

Remappings resolve exclusively to these local files. Although upstream libraries expose additional utility functions, only reachable application/token code is compiled into their deployed runtimes. The deployment test checks both actual runtimes for size and forbidden `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT` opcodes, skipping PUSH data.
