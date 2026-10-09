# FOMO6 Flap integration candidate

## Status (2026-10-07)

New sources: src/FOMO6FlapFactory.sol and src/FOMO6FlapVault.sol. The existing website/local +30 prototype has NOT been silently replaced. No actual BSC deployment or token launch occurred. All fork transactions execute inside local Foundry EVM only; RPC reads existing public chain state.

Official interfaces in src/flap were copied byte-for-byte from flap-sh/FlapVaultExample commit 5949cc7eb99bcb5ac5f679cc710ae456e627f12a. Interface dependencies were copied from the same upstream tree, licenses retained. No proxy or owner is used by this factory/vault. External Flap protocol contracts still have their own trust and upgrade assumptions.

## Launch order

1. Deploy the factory first, supplying fixed post-settlement recipient.
2. Choose Custom Vault in Flap and provide the FACTORY address, not a preexisting game address.
3. VaultPortal gives the factory the predicted token address. Factory creates one game for it before token code exists.
4. Flap creates the token and its TaxProcessor with marketAddress pointing to the game.
5. Anyone can bindTaxProcessor(), or the first enter() verifies and binds automatically. No caller-supplied processor parameter. It reads the immutable token's processor, checks token link, marketAddress, decimals=18 and native WBNB configuration, then locks once.
6. Native tax dispatch invokes receive(). It NEVER calls external contracts. Early payments are kept by sender in pendingBySource; verified processor pending revenue is credited once at binding. Other senders' early funds and forced BNB are excluded from jackpot. After binding, normal non-processor native transfers revert.

Waiting, six-hour cap, +30 seconds, 20,000-token DEAD transfer, permissionless settlement, winner-only one-time pull claim paid exclusively to the winner address and fixed post-settlement tax recipient remain. Settlement counts tax already credited at settlement, including receipts after expiry but before settlement. No randomness, auto-timer transaction, automatic claim or automatic restart.

## User-approved Guardian emergency exception

The user expressly accepted Flap Guardian emergency recovery on 2026-10-07 after explanation of its ability to withdraw the jackpot. This changes the original no-third-party-withdrawal guarantee.

- onlyGuardian resolves the hardcoded Flap Guardian for the deployed chain. Deployer/player have NO emergency authority.
- emergencyWithdrawNative(address to) may be called at ANY time, including after settlement before claim. There is no on-chain proof of an emergency, no timelock and no community vote. Guardian selects the destination and can transfer ALL BNB, including winner liability, pending and forced funds.
- First successful native emergency withdrawal irreversibly enters EMERGENCY_STOPPED, snapshots jackpotAtEmergency/postTaxesAtEmergency, zeros outstanding jackpot/post-tax liabilities and disables binding/entry/settle/claim/normal fee withdrawal. Existing winner/deadline/prizeAtSettlement history remains. Failed destination reverts the entire stop and bookkeeping.
- receive() remains cheap and accepts new funds during emergency into emergencyReceipts without making them claimable prizes. Guardian may recover later receipts again. No resume/reset setter exists.
- emergencyWithdrawToken(address token,address to) recovers ERC20 balances held BY THE VAULT. It cannot use players' allowances or recover already-burned tokens. It does not stop the native-funded round because accidental-token recovery does not consume prize assets.
- Both functions are nonReentrant. No configurable emergency auto-forward feature was added.
- Website for any public launch must prominently disclose this trust assumption and disable ordinary game writes/show stopped status when emergencyStopped=true. The current prototype website does not expose these recovery functions because its current game does not contain them.

References: official Rule 009 requires Guardian recovery for non-upgradeable vaults; official README recommends Guardian-controlled proxies as the alternative. Neither is fully permissionless custody. Do not call this variant an absolutely administrator-free jackpot.

## Validation

Factory validates V3 tax token, native quote, buy/sell 300bps, market allocation10000bps, no separate deflation/dividend/LP allocation. UI policy hints mirror constraints. vaultData must be empty; recipient/timer/price are not launch-form settings. Flap platform fees still precede market payout, so all-market allocation is not all gross trading tax.

Local mocked full launch covers predicted token before code, early dispatch, permissionless one-time binding, wrong links/quote/decimals, arbitrary/forced funds, native gas budget, malicious winner/retry/reentrancy, state/settlement/claim, 100/1000/10000 entries and fuzz. The invariant runs256×128 operations and drains normal liabilities at the end. Emergency tests cover unauthorized caller, pre-binding/active/settled recovery, failed destination rollback, later receipts, reentrancy and invalid recipients.

Real-protocol BSC mainnet LOCAL FORK passed at block126235485 with the Guardian-enabled source: factory → V3 launch → .1BNB curve buy → dispatch → bind → burn entry → expiry → settle → complete prize claim. Buy/sell tax checked300bps and totalSupply1b ×10^18. Actual net prize .0027BNB from gross .003BNB tax, reflecting platform deductions. The reference fixture's tax duration100years/anti-farmer1day are TEST PARAMETERS, not a final launch recommendation.

Command (READ-ONLY network fork, no broadcast):

```sh
FOMO6_FLAP_FORK_RPC=https://bsc-dataseed.bnbchain.org FOMO6_FLAP_FORK_BLOCK=126235485 FOUNDRY_GAS_LIMIT=3000000000 .tools/forge test --offline --evm-version cancun --match-contract FOMO6FlapForkTest -vv
FOUNDRY_GAS_LIMIT=3000000000 .tools/forge test --offline --match-contract 'FOMO6Flap(Test|VaultInvariant)'
```

The fork suite skips when its RPC environment variable is absent; a skip is not a pass. Fork uses Cancun because the live protocol executes newer EVM opcodes; default existing prototype build remains Paris. Salt is mined off-chain, avoiding an unbounded in-EVM search, and pinned to an otherwise-unused CREATE2 token address.

## Remaining limits

- Actual BSC Testnet factory deployment and launch/dispatch with the user's wallet remain. This requires the user personally signing; no private key or mnemonic is requested.
- Mainnet fork success is not proof the Testnet deployment or every future Flap upgrade is identical. Re-check real addresses/implementation/parameters before signed launch.
- Only bonding-curve buy/dispatch path was verified against real protocol so far. DEX graduation, tax threshold liquidations and sell-side tax distribution still need real-protocol fork coverage before a production launch.
- No independent third-party audit or Flap endorsement is claimed. Spec/UI review is partial: the fixed-price enter() schema has no amount input, so generated Flap UI may not auto-approve it. Use the FOMO6 DApp for entry until that UI path is verified. Guardian authorization for winner-only claim is deliberately not allowed to impersonate winner; recovery uses its separate emergency methods.
- V3 ERC20 quote ping/balance-delta accounting is intentionally unsupported (factory rejects ERC20 quotes).
- External token transfer failure can block new entries; protocol dispatch failure or withheld dispatch delays jackpot receipt. Flap fee/upgrade/key risks remain even though game price/timer/payout recipient have no setters.

## Testnet handoff

Deploy script script/DeployFlapFactory.s.sol rejects chain56 and supports ONLY97. Fixed recipient for this project:0xeC4ee45e56795B85Ad73218566442Aa8b1310263. Verify it in the unsigned deployment transaction before signing.

Compile Solidity0.8.28, optimizer200, Paris for the default project; use the exact chosen settings for verification. Upload factory source/imports or generated flattened source in Remix, connect MetaMask to BSC Testnet97, deploy with recipient, personally confirm. Verify source using standard-json compiler input (includes canonical Flap and OpenZeppelin sources), compare runtime/settings, and record the factory receipt/address. Do not deploy this script to Mainnet.

At launch use Custom Vault, factory address, V3 token, BNB quote,3% buy/3% sell,100% market allocation, other allocations0, no commission, empty vault parameters. Source verification and a successful testnet launch do not remove the need for remaining review/tests. Game address is recovered from VaultCreated event or factory.vaultForToken(token).

2026-10-09: claim() no longer accepts a payout destination. A permanently rejecting winner cannot use an alternate address; this user-requested restriction may lock its normal prize claim.

## Permissionless tax collection

`collectTaxes()` verifies/binds the token processor and calls its `dispatch()`. Only native BNB actually delivered through the verified receipt path is credited. It does not start or extend the timer. Collection after settlement credits post-settlement taxes, not the winner. Pending unswapped token taxes are not forcibly liquidated. Dispatch failure reverts collection; entry and settlement do not depend on collection success. All game actions are blocked during dispatch, while its native receipt callback is accepted.

`enter()` now attempts dispatch after a valid entry, with 300,000 gas forwarded and 60,000 gas headroom required. Processor failure or insufficient headroom emits AutoTaxCollection(false) and leaves the entry valid. No return data is copied. Explicit collectTaxes remains available to retry complex dispatches. The bound is a gas budget, not a production fee estimate; real processor gas must be measured on a protocol fork and Testnet. collectTaxes is exposed in vaultUISchema.
