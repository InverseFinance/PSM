# PSM

### Key Features

- **Direct Minting/Redemption**: Buy DOLA with collateral or sell DOLA for collateral
- **ERC4626 Vault Integration**: Collateral is automatically deposited into yield-generating vaults
- **Fed Integration**: Automated DOLA supply management through PSMFed contract
- **Configurable Fees**: Adjustable buy/sell fees to manage protocol economics
- **Profit Distribution**: Automatic profit taking from vault yields to governance
- **Vault migration**: Allows to migrate into a new vault automatically or manually via governance if some deposit or redeem limits in the vaults.

### Core Contracts

#### PSM.sol
The main contract that handles:
- DOLA buying and selling in exchange for collateral
- Collateral management through ERC4626 vaults
- Fee collection and profit distribution
- Vault migration capabilities
- Governance controls

#### PSMFed.sol
Federal Reserve-style contract for DOLA supply management:
- Mint new DOLA for PSM operations (expansion)
- Burn DOLA to reduce supply (contraction)
- Supply cap enforcement
- Chair-based monetary policy controls

#### Controller.sol
Access control layer for buy/sell operations:
- Validates transaction permissions
- Can implement custom logic for rate limiting, KYC, etc.
- Currently allows all operations (template implementation)

