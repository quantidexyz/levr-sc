# LevrFactory_v1

## Glossary

- **Project**: A set of contracts (Treasury, Staking, Governor, StakedToken) deployed for a specific Clanker token.
- **Trusted Factory**: A Clanker factory address that Levr trusts. Only tokens created by these factories can be registered on Levr.
- **Config Bounds**: A set of minimum/maximum safety limits (guardrails) for governance parameters to prevent unsafe configurations.
- **Delegatecall**: A low-level Solidity feature where a contract executes code from another contract _in its own context_ (using its own storage).
- **Protocol Fee**: A global fee taken on staking actions, configurable by the protocol owner.

## Overview

`LevrFactory_v1` is the "Brain" of the protocol. It is the central registry where new projects are created. It holds the global configuration and ensures that all deployed projects adhere to safety standards. It uses a specialized deployment architecture to save gas and code size.

## Architecture

- **Implementation**: `LevrFactory_v1.sol`
- **Inheritance**: `Ownable`, `ReentrancyGuard`, `ERC2771Context`.
- **Helper**: `LevrDeployer_v1` (Linked via immutable address).

## Complex Logic Explained

### 1. Delegatecall Deployment Architecture

**Problem**: The Factory contract is very large. If it included all the code to deploy the Treasury, Staking, Governor, and Token contracts, it might exceed the Ethereum contract size limit (24KB).
**Solution**:

- We moved the deployment logic into a separate contract: `LevrDeployer_v1`.
- When `register()` is called on the Factory, the Factory performs a `delegatecall` to the Deployer.
- **Effect**: The Deployer's code runs, but it acts _as if_ it were the Factory. It uses the Factory's storage and address. This keeps the Factory "lean" while allowing complex deployment logic.

### 2. Configuration Hierarchy (Defaults vs. Overrides)

**Concept**: We want good defaults for everyone, but verified projects might need custom settings.
**Logic**:

- **Global Config**: Stored in the Factory (`protocolFeeBps`, `votingWindowSeconds`, etc.).
- **Project Config**: Stored in `_projectOverrideConfig` mapping.
- **Resolution**: When asking "What is the voting window for Token X?", the logic is:
  1. Is Token X "Verified"?
  2. **Yes** -> Return Token X's custom config.
  3. **No** -> Return the Global Default config.
- This allows the protocol to update defaults for everyone instantly, while respecting the custom needs of mature, verified projects.

### 3. Trusted Factory Validation

**Concept**: Levr is designed for Clanker tokens. We don't want random scam tokens registering.
**Logic**:

- The Factory maintains a list of `_trustedClankerFactories`.
- When someone calls `register(tokenAddress)`, the Factory asks the Trusted Factories: "Do you know this token?"
- If a Trusted Factory confirms "Yes, I created this token," registration proceeds.
- If no Trusted Factory claims the token, registration reverts.

## API Reference

### Functions

#### Registration

- `register(address clankerToken)`: Main entry point. Checks trust, deploys contracts, initializes project.
- `prepareForDeployment()`: Optional step. Deploys just the Treasury/Staking first. Useful if you need the Treasury address _before_ the Clanker token is fully set up.

#### Config Management

- `updateConfig(...)`: Updates global defaults.
- `updateProjectConfig(...)`: Updates specific project settings (must be Verified).
- `verifyProject(...)` / `unverifyProject(...)`: Toggles a project's ability to use custom configs.

#### Views

- `getProject(address token)`: Returns the addresses of the deployed contracts.
- `streamWindowSeconds(address token)`, `proposalWindowSeconds(address token)`, etc.: Returns the active config parameter for a specific project (resolving the hierarchy).

## Events

- `Registered`: A new project is born.
- `ConfigUpdated`: Defaults changed.
- `ProjectVerified`: A project gained independence.

## Errors

- `TokenNotTrusted`: The token didn't come from a valid Clanker factory.
- `InvalidConfig`: You tried to set a parameter (like fee or window) that violates the safety Guardrails.
