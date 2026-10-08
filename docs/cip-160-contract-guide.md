# Contract use of proposed protected addresses and Receiving

This guide describes the per-output CIP-160 contract proposed for Dijkstra
protocol major version 12 and receiving-aware Plutus V4. The
[CIP amendment](https://github.com/colll78/CIPs/pull/1) and
[Plutus interface](https://github.com/colll78/plutus/pull/1) are published
for review; upstream format agreement and network activation remain outstanding.
Integration and activation require coordinated ledger, Plutus, formal, API, CLI
and node releases. Review evidence and release requirements are linked below;
this is not a mainnet deployment guide.

Execution per output is this implementation's proposed reconciliation of
[CIP-160's per-output validation rule](https://github.com/cardano-foundation/CIPs/blob/b4a593c960f2751fef2ddc8df28bec7b22c68eb5/CIP-0160/README.md#receiving-validation-rule)
and [lehins's suggestion to resolve a TxOut into the purpose](https://github.com/cardano-foundation/CIPs/pull/1063#issuecomment-3222306948).
Those sources support individual output validation and visibility; the exact raw
output-index mapping and Data fields below are our proposed implementation
decisions, rather than evidence of upstream agreement on those formats.

## Recipient authorization

A protected address requires authorization when an ordinary transaction output is
created at that address. A protected key recipient must sign the creating body.
For a child output, the signature must cover that child's body hash; a signature
over the enclosing body is insufficient. A protected native-script recipient
supplies a satisfied native script. A protected Plutus recipient supplies the
script, a body-local Receiving redeemer and execution budget. Subsequent spending
uses the existing Spending purpose and payment credential; protection does not
introduce a second spending rule. Receiving key signatures do not implicitly add explicit guards.

The same credential can occur at an ordinary unprotected address. Contracts
relying on recipient authorization must inspect the address protection form in
outputs, consumed inputs and reference inputs where that matters. Protection
alone does not enforce global state uniqueness, one token or UTxO per protocol,
or every invariant historically enforced by state tokens.

## Validate the specific receiving output

Each protected Plutus output requires its own Receiving execution, redeemer and
budget, even when several outputs have the same payment hash or identical
contents. The pointer is the raw original zero-based index in the containing
body's authored output sequence, not a filtered rank or a sorted hash position.
Key, native and ordinary outputs do not shift or compress those indexes. Native
scripts use existing phase-1 checks and require no Plutus Receiving redeemer.
Use the ledger's output-purpose/pointer interfaces for construction and lookup.

The receiving-aware context identifies this specific output and its original
index. `scriptContextScriptHash` still identifies the executing recipient script.
Validate the selected output's datum, value and staking conditions. A validator
may additionally inspect other visible outputs for contract-specific invariants,
but a successful invocation cannot authorize a second protected Plutus output.
Even byte-identical duplicates have different purposes and independent budgets.

Receiving remains local to the containing body: a parent and child with the same
hash and output index have separate purposes, redeemers and integrity domains.
There is no implicit datum argument; datum contents come from the selected
output or existing permitted datum witnesses.

The [receivingEvenDatum fixture](../libs/plutus-preprocessor/src/Cardano/Ledger/Plutus/Preprocessor/Source/V4.hs)
checks an even inline integer datum on its resolved Receiving output and an even
datum when Spending. Other purposes fail. The `receivingRedeemerMatchesDatum`
fixture additionally checks the raw output index, resolved output and recipient
hash, then matches its redeemer to that output's inline integer datum. This
allows separate same-hash outputs to receive different instructions.

The [ledger lifecycle tests](../eras/dijkstra/impl/testlib/Test/Cardano/Ledger/Dijkstra/Imp/ReceivingAdversarialSpec.hs)
define creation and subsequent Spending with the same validator, independent
same-hash/identical-output purposes and malformed-output rejection. The creating
body uses Receiving; the consuming body uses Spending. These cases exercise
compiled validators and distinct output contexts, rather than abstract evaluator
results alone.

An inline datum exposes contents directly. A datum hash alone does not reveal its
preimage or create an automatic phase-1 preimage requirement. A contract can
instead look up contents in existing permitted datum witnesses. The fixture
intentionally requires inline datums rather than accepting hashes it cannot
inspect. V4 preserves `Maybe AccountId` staking representation; it does not
reintroduce pointer-capable V1 staking credentials.

Receiving sees the body containing its purpose, including its outputs, consumed
inputs and reference inputs. It does not implicitly see siblings or the enclosing
body. Wider batch conditions need the supported Guarding mechanisms. Guarding's
full and simplified views preserve protected addresses and recognize Receiving
redeemer hashes.

## Witnesses and failure behavior

Scripts on selected consumed or reference inputs may satisfy Receiving through
the existing script availability rules. A reference script attached only to a new
output cannot authorize its own creation. The same script may run under Receiving
and Spending with distinct redeemers and budgets. Budgets and fees aggregate over
the batch, while redeemer pointers and script-integrity hashes belong to bodies.

A child-only Plutus Receiving invocation requires the top-level collateral checks.
Key/native-only Receiving adds no Plutus collateral requirement. Protected
collateral-return outputs are rejected in phase 1. Failed Receiving creates no
ordinary outputs in any body. A matching phase-2-invalid transaction can still
follow the existing collateral-only path; a transaction claiming validity is
rejected when its Plutus scripts fail.

V1-V3 contexts cannot represent protected addresses or Receiving purposes.
Collection fails in phase 1 when the required legacy view includes protected
outputs or consumed inputs, including key or native-script recipients. V2 and V3
also expose reference inputs and reject protection there. V1 hides reference
inputs, so their protection alone does not prevent collection; its existing
missing-input, Byron-address and inline-datum validation still applies.
Dijkstra already rejects legacy languages in subtransactions. These restrictions
are applied to actual context visibility and do not imply a blanket ban on all
mixed-language batches.

## Migration and reproducibility

A transaction executing an old-language contract may be unable to create a
protected replacement output because its context cannot represent that output.
Do not promise an atomic legacy-to-protected migration. A supported strategy can
require an intermediate unprotected output or a contract-specific upgrade path;
each stage needs its own authorization and invariant analysis. Recompiling under
V4 can change the script hash. There is no general promise that an existing hash
is retained.

The proposed V4 Address Data schema uses
`Constr 0 [paymentCredential, optionalAccount]` for ordinary addresses and
`Constr 1 [paymentCredential, optionalAccount]` for protected addresses. Existing
V4 clients must update and V4 validators must be recompiled. Released V1-V3
schemas remain unchanged. Receiving uses Data constructor index 7 with an
output-specific payload: `Receiving ScriptHash Integer` is
`Constr 7 [scriptHash, originalOutputIndex]`;
`ReceivingScript Integer TxOut` is `Constr 7 [originalOutputIndex, resolvedOutput]`.
Ledger item and pointer views both carry the original `Word32` output index;
lookup verifies that index is a protected script output in the same body. Ledger
CBOR redeemer tag 7 and Plutus Data constructor index 7 are separate assignments;
Guarding retains tag/index 6.

Compile the fixture source through the repository's real Plutus preprocessor:

```sh
cabal run plutus-preprocessor
```

This generates the public test fixture module
`libs/cardano-ledger-core/testlib/Test/Cardano/Ledger/Plutus/Examples.hs`.
The command requires the patched receiving-aware Plutus dependency pinned in
[cabal.project](../cabal.project). A released Plutus 1.71 package does not contain
this proposed interface. The current proposal is
[`dcbb7e3232c3322557410fe341ec84f3cd78dc04`](https://github.com/colll78/plutus/tree/dcbb7e3232c3322557410fe341ec84f3cd78dc04).
When regenerating fixtures, verify reproducible output and preserve the existing
V1-V3 fixture byte strings.

The matching formal source is
[`87072fed43a085bbbaaeb5888a7792ec5f8a164a`](https://github.com/colll78/formal-ledger-specifications/commit/87072fed43a085bbbaaeb5888a7792ec5f8a164a),
with generated artifact
[`b747be78f6e001d41395974251cf0b42f45b68c4`](https://github.com/colll78/formal-ledger-specifications/commit/b747be78f6e001d41395974251cf0b42f45b68c4)
pinned by Cabal and Nix. Its 789 generated files were matched byte-for-byte to
genuine signed-source Shake extraction; manifest SHA-256 is
`8d0d123d8eb3728884ad272c00f18169c1244fe43563df18af28d813c41ff535`.
Model execution has documented foreign-evaluator and context abstractions;
concrete ledger validator tests and integrated conformance provide complementary
checks. See the [formal conformance guide](cip-0160-formal-conformance.md).

## Verification and release requirements

Use the [ledger proposal](https://github.com/colll78/cardano-ledger/pull/1),
[Plutus proposal](https://github.com/colll78/plutus/pull/1) and
[formal proposal](https://github.com/colll78/formal-ledger-specifications/pull/1)
for current validation evidence. Coordinated consumers are the
[API](https://github.com/colll78/cardano-api/pull/2),
[CLI](https://github.com/colll78/cardano-cli/pull/1),
[consensus main](https://github.com/colll78/ouroboros-consensus/pull/2),
[consensus release](https://github.com/colll78/ouroboros-consensus/pull/3) and
[node](https://github.com/colll78/cardano-node/pull/1) proposals. A passing
checkpoint applies to its recorded source and test scope; it is not evidence
that a later revision, deployment or untested runtime boundary is safe.

Concrete validator tests complement the formal model's abstract evaluator and
contexts. Conformance compares translated state and acceptance/rejection, not
exact failure payloads or concrete UPLC execution. Native WASM goldens do not
establish browser execution or JavaScript binding compatibility. Benchmark smoke
checks do not establish performance neutrality or node throughput.

Release requires agreement on the address/language formats and activation
version, compatible accepted dependencies, integrated conformance and CI.
Fork CI validates the formal artifact pin against its allowed declared artifact
branch; that provenance check does not establish upstream source acceptance or
upstream artifact ancestry. Development-fork publication is not release approval.

Node coverage must establish legacy-contract migration, scheduled activation,
persisted-state restart and restoration, snapshot restoration, rollback, and
Leios endorser-block Receiving accounting and validation. Current-format relay
restart and ledger translation/snapshot checks do not establish old-format
restoration or those wider workflows. Receiving-specific browser/binding checks
need independent evidence. Native toolchain and broader consensus integration
also require their own coverage. No network rollout readiness or overall
cost/efficiency claim follows from the scoped checks.
