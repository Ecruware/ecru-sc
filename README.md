# <h1 align="center">Ecru</h1>

**Ecru** is a novel credit market that supports different internal and external use cases for protocol-created credit. Internally, credit can be extended as a credit line to borrow vaults facilitating specialized credit markets. Externally, credit can be minted in the form of a protocol-issued stablecoin and utilized within the greater DeFi ecosystem. The bootstrapping of new credit markets around the proposed protocol is further facilitated by the permissionless onboarding of borrow vaults.

## Contents
- [Whitepaper](./docs/Ecru-Whitepaper.pdf)
- [Technical Documentation](./docs/documentation.md)
- [License](./LICENSE)
- [Getting Started](#requirements)

## Requirements
This repository uses Foundry for building and testing and Hardhat for deploying the contracts.
If you do not have Foundry already installed, you'll need to run the commands below.

### Install Foundry
```sh
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Install Node, NPM and Yarn
Install [Node and NPM](https://nodejs.org/en/download)
```sh
npm install -g yarn
```

### Set .env
Copy and update contents from `.env.example` to `.env`

## Building and Testing

```sh
git clone https://github.com/ecruware/ecru-sc
cd ecru-sc
make # installs the project's contract dependencies.
make test
```
## Deploying

```sh
yarn # installs the project's js dependencies
make anvil
make deploy-anvil # in a separate terminal
```
