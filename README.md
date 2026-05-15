# DecentralizedGig HK — Smart Contracts (Hardhat)

Solidity smart contracts for **DecentralizedGig HK**: multi-milestone escrow, gig registry, mock HKD stablecoin, DGIG token, and UUPS-upgradeable protocol modules. Target network: **Polygon Amoy** testnet (chain ID `80002`).

## Prerequisites

- [Node.js](https://nodejs.org/) 18+ (22 recommended)
- npm 9+
- For Amoy deployment: a funded wallet with test MATIC and a private key

## Project structure

```
contracts/
├── contracts/          # Solidity sources
│   ├── Escrow.sol
│   ├── GigRegistry.sol
│   ├── GigFactory.sol
│   ├── MockHKD.sol
│   ├── DGIGToken.sol
│   └── interfaces/
├── scripts/
│   └── deploy.ts       # Main deployment script
├── test/               # Hardhat + Chai tests (TypeScript)
├── hardhat.config.ts
└── package.json
```

## Setup

```bash
cd contracts
npm install
```

Copy the environment template and fill in values for testnet deployment:

```bash
cp .env.example .env
```

| Variable | Description |
|----------|-------------|
| `AMOY_RPC_URL` | Polygon Amoy RPC (default: `https://rpc-amoy.polygon.technology`) |
| `DEPLOYER_PRIVATE_KEY` | Deployer wallet private key (never commit real keys) |

## Compile

Compile all contracts and generate artifacts in `artifacts/`:

```bash
npm run compile
# or
npm run build
```

Clean cached artifacts and recompile from scratch:

```bash
npm run clean
npm run compile
```

## Test

Run the full test suite (local Hardhat network):

```bash
npm test
```

Run a single test file:

```bash
npx hardhat test test/Escrow.skel.ts
```

## Deploy

### Local Hardhat network (development)

Deploys to an ephemeral in-process chain (no gas or keys required):

```bash
npm run deploy
# equivalent to:
npx hardhat run scripts/deploy.ts --network hardhat
```

The script deploys (UUPS proxies where applicable):

- `MockHKD` — test HKD stablecoin
- `DGIGToken` — utility token stub
- `GigRegistry` — gig listings
- `Escrow` — implementation contract
- `GigFactory` — creates gigs + escrow proxies

Printed addresses can be copied into `frontend/.env.local` (see `frontend/.env.example`).

### Polygon Amoy testnet

1. Set `DEPLOYER_PRIVATE_KEY` and optionally `AMOY_RPC_URL` in `.env`.
2. Fund the deployer with [Amoy MATIC](https://faucet.polygon.technology/).
3. Deploy:

```bash
npm run deploy:amoy
# equivalent to:
npx hardhat run scripts/deploy.ts --network amoy
```

After deployment, wire the frontend:

```env
NEXT_PUBLIC_GIG_REGISTRY_AMOY=<GigRegistry address>
NEXT_PUBLIC_GIG_FACTORY_AMOY=<GigFactory address>
NEXT_PUBLIC_MOCK_HKD_AMOY=<MockHKD address>
NEXT_PUBLIC_ARBITRATOR_AMOY=<deployer or multisig address>
```

## Toolchain

| Tool | Version / notes |
|------|-----------------|
| Hardhat | 2.x |
| Solidity | 0.8.28, Cancun EVM |
| OpenZeppelin Contracts | 5.6 (upgradeable + standard) |
| TypeScript | Tests and deploy scripts |
| `@openzeppelin/hardhat-upgrades` | UUPS proxy deployment |

## Common commands

| Command | Description |
|---------|-------------|
| `npm run compile` | Compile contracts |
| `npm test` | Run all tests |
| `npm run deploy` | Deploy to local Hardhat network |
| `npm run deploy:amoy` | Deploy to Polygon Amoy |
| `npm run clean` | Remove `cache/` and `artifacts/` |

## Security notes

- Never commit `.env` or private keys.
- UUPS contracts restrict upgrades to `owner()`; use a multisig on mainnet.
- `MockHKD` is for **testnet only**, not production HKD.
- Review escrow and dispute flows before mainnet deployment.

## License

ISC (see `package.json`).
