# FOMO6

Open-source, single-round Last Sender Wins experiment for BNB Chain, using a Flap tax token. **Development candidate: not deployed to BSC Testnet or Mainnet; not independently audited or Flap-verified.**

## Rules

- Each successful entry transfers exactly 20,000 18-decimal tokens to the fixed DEAD address. This removes tokens from circulation; it does not reduce ERC20 totalSupply.
- First entry starts six hours. Later entries add 30 seconds, capped at six hours remaining. Entries at or after the deadline revert.
- Anyone may settle once. Last successful sender wins; only the winner may claim the complete recorded jackpot once, only to the winner address.
- Verified native BNB tax receipts fund the jackpot. At settlement the prize is fixed; subsequent receipts belong only to the immutable recipient chosen when deploying the factory. Anyone may trigger their withdrawal to that fixed recipient.
- Taxes received after expiry but before settlement still belong to the jackpot. No automatic settlement, payout or restart. No buyback functionality.
- No owner, configurable game rules, proxy or upgrades. **Flap Guardian has an explicit emergency exception: it may withdraw ALL vault BNB, including an unclaimed prize, and permanently stop the round.** See `docs/SECURITY.md`.

## Main sources

`src/FOMO6FlapFactory.sol` creates `src/FOMO6FlapVault.sol` through the Flap Custom Vault launch flow. `src/FOMO6.sol` is a legacy test-helper dependency, not the deployment target.

## Local tests

Install Foundry, then run from this folder:

```sh
FOUNDRY_GAS_LIMIT=3000000000 forge test --match-contract 'FOMO6Flap(Test|VaultInvariant)' -vv
```

Solidity 0.8.28, optimizer 200, Paris. Vendored dependencies and licenses are included. Latest local result: 26 tests pass, including 1,000 fuzz runs, 256 x 128 invariant actions, malicious winner/reentrancy, emergency recovery, and 100/1,000/10,000 entries. The enlarged test gas limit is for aggregation; it is not a production block limit.

An optional LOCAL fork test reads live public BSC state but never broadcasts:

```sh
FOMO6_FLAP_FORK_RPC=https://bsc-dataseed.bnbchain.org FOUNDRY_GAS_LIMIT=3000000000 forge test --evm-version cancun --match-contract FOMO6FlapForkTest -vv
```

Without RPC configuration that test skips; a skip is not a pass. See `docs/SECURITY.md` for remaining validation.

## BSC Testnet deployment

`script/DeployFlapFactory.s.sol` rejects chains other than 97. Set `POST_SETTLEMENT_RECIPIENT` to your intended fixed wallet, then use an encrypted Foundry account or hardware wallet to sign. Never store private keys or mnemonic phrases in this repository. Deploy and verify the factory first, then supply its address in Flap Custom Vault; Flap calls it with the predicted token address to create the game. Confirm native BNB quote, 3% buy/sell tax and all net market allocation to the vault. Verify compiler standard-JSON sources and constructor arguments on Testnet BscScan. No Mainnet script is supplied.

## License

MIT. Third-party code retains its original licenses. Open source does not mean audited or risk-free.
