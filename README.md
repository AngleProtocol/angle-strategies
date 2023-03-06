# <img src="logo.svg" alt="Angle Strategies" height="40px"> Angle Project Strategies

[![CI](https://github.com/AngleProtocol/strategies-dev/workflows/CI/badge.svg)](https://github.com/AngleProtocol/strategies-dev/actions?query=workflow%3ACI)

## Documentation

### To Start With

Like many yield aggregators, Angle implements yield strategies to provide the best yields to its LPs, and to make a revenue for veANGLE holders. This repo contains the strategies implemented on the Angle Protocol.

Documentation to understand Angle Protocol's strategies is available [here](https://docs.angle.money/angle-core-module/lending).

Developers documentation to understand the smart contract architecture is available [here](https://developers.angle.money/core-module-contracts/smart-contracts-docs/adapters).

### Further Information

For a broader overview of the protocol and its different modules, you can also check [this overview page](https://developers.angle.money) of our developers documentation.

Other Angle-related smart contracts can be found in the following repositories:

- [Angle Borrowing module contracts](https://github.com/AngleProtocol/angle-borrow)
- [Angle Core module contracts](https://github.com/AngleProtocol/angle-core)
- [Angle Direct deposit module contracts](https://github.com/AngleProtocol/angle-amo)

Otherwise, for more info about the protocol, check out [this portal](https://linktr.ee/angleprotocol) of resources.

## Starting

### Install packages

You can install all dependencies by running

```bash
yarn
forge i
```

### Create `.env` file

In order to interact with non local networks, you must create an `.env` that has:

- `PRIVATE_KEY`
- `MNEMONIC`
- network key (eg. `ALCHEMY_NETWORK_KEY`)
- `ETHERSCAN_API_KEY`

For additional keys, you can check the `.env.example` file.

Warning: always keep your confidential information safe.

## Headers

To automatically create headers, follow: <https://github.com/Picodes/headers>

## Hardhat Command line completion

Follow these instructions to have hardhat command line arguments completion: <https://hardhat.org/hardhat-runner/docs/guides/command-line-completion>

## Foundry Installation

```bash
curl -L https://foundry.paradigm.xyz | bash

source /root/.zshrc
# or, if you're under bash: source /root/.bashrc

foundryup
```

To install the standard library:

```bash
forge install foundry-rs/forge-std
```

To update libraries:

```bash
forge update
```

### Foundry on Docker 🐳

**If you don’t want to install Rust and Foundry on your computer, you can use Docker**
Image is available here [ghcr.io/foundry-rs/foundry](http://ghcr.io/foundry-rs/foundry).

```bash
docker pull ghcr.io/foundry-rs/foundry
docker tag ghcr.io/foundry-rs/foundry:latest foundry:latest
```

To run the container:

```bash
docker run -it --rm -v $(pwd):/app -w /app foundry sh
```

Then you are inside the container and can run Foundry’s commands.

### Compilation

```bash
yarn hardhat:compile
yarn foundry:compile
```

### Tests

You can run tests as follows:

```bash
forge test -vvvv --watch
forge test -vvvv --match-path contracts/test/forge/testXX1.t.sol
forge test -vvvv --match-test "testAbc*"
forge test -vvvv --fork-url https://eth-mainnet.alchemyapi.io/v2/Lc7oIGYeL_QvInzI0Wiu_pOZZDEKBrdf
```

You can also list tests:

```bash
forge test --list
forge test --list --json --match-test "testXXX*"
```

### Deploying

There is an example script in the `scripts/foundry` folder. Then you can run:

```bash
yarn foundry:deploy <FILE_NAME> --rpc-url <NETWORK_NAME>
```

Example:

```bash
yarn foundry:deploy scripts/foundry/DeployMockAgEUR.s.sol --rpc-url goerli
```

### Coverage

We recommend the use of this [vscode extension](ryanluker.vscode-coverage-gutters).

```bash
yarn hardhat:coverage
yarn foundry:coverage
```

### Gas report

```bash
yarn foundry:gas
```

## Slither

```bash
pip3 install slither-analyzer
pip3 install solc-select
solc-select install 0.8.11
solc-select use 0.8.11
slither .
```

## Media

Don't hesitate to reach out on [Twitter](https://twitter.com/AngleProtocol) 🐦
