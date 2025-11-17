# Levr Factory Ownership - Gnosis Safe Multisig

**Date Created:** October 30, 2025  
**Status:** Production Deployment Required  
**Fix:** [H-4] Factory Owner Centralization

---

## 🎯 Overview

The Levr Factory ownership is secured by a **Gnosis Safe 3-of-5 multisig** to prevent single-point-of-failure and ensure decentralized control over critical protocol parameters.

## 🔐 Multisig Configuration

### Parameters

| Parameter     | Value                         |
| ------------- | ----------------------------- |
| **Type**      | Gnosis Safe (Base Mainnet)    |
| **Threshold** | 3 of 5 signatures required    |
| **Chain**     | Base Mainnet (Chain ID: 8453) |
| **Purpose**   | LevrFactory_v1 ownership      |

### Powers

The multisig controls:

✅ **Factory Configuration**

- Update protocol fee (0-100%)
- Adjust governance parameters (quorum, approval, etc.)
- Modify staking parameters (maxRewardTokens, streamWindow)

✅ **Trusted Clanker Factories** (FIX [C-1])

- Add/remove trusted Clanker factory versions
- Manage multi-version factory support

✅ **Emergency Actions**

- Pause/unpause projects (if implemented)
- Update protocol treasury address

❌ **Cannot Control**

- Individual project treasuries (controlled by each project's governor)
- User funds in staking contracts
- Proposal execution (controlled by governance votes)

---

## 👥 Signer Configuration

**⚠️ TO BE COMPLETED BEFORE MAINNET**

Update this section with actual signer addresses and roles:

### Signers

| #   | Role              | Address | Contact          |
| --- | ----------------- | ------- | ---------------- |
| 1   | Lead Developer    | `0x...` | name@example.com |
| 2   | Protocol Engineer | `0x...` | name@example.com |
| 3   | Security Lead     | `0x...` | name@example.com |
| 4   | Operations        | `0x...` | name@example.com |
| 5   | Community Rep     | `0x...` | name@example.com |

### Geographic Distribution

- [ ] At least 3 different time zones
- [ ] At least 2 different countries
- [ ] No more than 2 signers from same organization

### Security Requirements

- [ ] All signers use hardware wallets (Ledger/Trezor)
- [ ] Backup keys stored in secure locations
- [ ] Regular signer availability checks (monthly)
- [ ] Emergency contact protocol established

---

## 📋 Deployment Checklist

### Pre-Deployment

- [ ] Identify and verify 5 signer addresses
- [ ] Confirm all signers have hardware wallets
- [ ] Establish secure communication channel (e.g., Signal group)
- [ ] Document emergency procedures

### Deployment Steps

1. **Deploy Gnosis Safe**

   ```bash
   # Use Gnosis Safe web interface at https://app.safe.global
   # Or deploy via script (see script/DeployMultisig.s.sol)
   
   Network: Base Mainnet
   Signers: [address1, address2, address3, address4, address5]
   Threshold: 3
   ```

2. **Verify Multisig**

   ```bash
   # Verify on BaseScan
   # Confirm all signers can access
   # Test with a small transaction
   ```

3. **Transfer Factory Ownership**

   ```bash
   # Option A: Via Foundry script
   forge script script/TransferOwnership.s.sol \
     --rpc-url $BASE_RPC_URL \
     --broadcast \
     --verify
   
   # Option B: Via cast (manual)
   cast send $FACTORY_ADDRESS \
     "transferOwnership(address)" \
     $MULTISIG_ADDRESS \
     --rpc-url $BASE_RPC_URL \
     --private-key $DEPLOYER_PRIVATE_KEY
   ```

4. **Verify Transfer**

   ```bash
   # Check factory owner
   cast call $FACTORY_ADDRESS "owner()(address)" --rpc-url $BASE_RPC_URL
   
   # Should return multisig address
   ```

### Post-Deployment

- [ ] Verify factory ownership transferred
- [ ] Test multisig by updating a non-critical parameter
- [ ] Document multisig address in all deployment docs
- [ ] Update frontend/SDK with multisig address
- [ ] Announce ownership transfer to community

---

## 🚨 Emergency Procedures

### Signer Compromise

If a signer's key is compromised:

1. **Immediate:** Create proposal to remove compromised signer
2. **Require:** 3 signatures from remaining signers
3. **Replace:** Add new signer address
4. **Notify:** Community via official channels

### Loss of Signer Access

If a signer loses access (2/5 remain):

1. **Still secure:** 3/5 threshold means protocol is still operational
2. **Proactive:** Begin process to add replacement signer
3. **Timeline:** Complete within 48 hours

### Critical Bug Discovered

If critical bug found requiring immediate action:

1. **Assess:** Determine if factory-level action needed
2. **Coordinate:** Emergency call with available signers
3. **Execute:** Pause mechanism (if H-6 implemented) or config update
4. **Communicate:** Transparent disclosure to community

---

## 📊 Governance vs Multisig

### Multisig Controls (Protocol-Level)

- Factory configuration parameters
- Trusted Clanker factories list
- Protocol fee and treasury
- Global staking parameters

### Governance Controls (Per-Project)

- Treasury spending proposals
- Staking boost allocations
- Project-specific parameters
- Community-driven decisions

**Separation of Concerns:** Multisig manages protocol infrastructure, governance manages project operations.

---

## 🔄 Future Transitions

### Path to Full Decentralization

**Phase 1: Launch (Current)**

- 3-of-5 multisig (team + community)
- Rapid response capability
- Centralized but distributed

**Phase 2: 6-12 Months**

- Expand to 4-of-7 multisig
- Add more community representatives
- Gradual power distribution

**Phase 3: 18+ Months**

- Transition to DAO governance
- Multisig becomes emergency backup
- Full community control

---

## 📝 Operational Guidelines

### Routine Operations

**Frequency:** As needed, typically monthly

**Process:**

1. Proposal drafted in GitHub issue
2. 48-hour review period
3. Multisig transaction created
4. Signers review and approve
5. Execute after 3+ signatures
6. Announce changes to community

### Trusted Factory Updates (C-1 Related)

**When to Update:**

- New Clanker factory version deployed
- Security issue with existing factory
- Deprecation of old factory version

**Process:**

1. Verify new factory on BaseScan
2. Test with non-production token
3. Create multisig transaction to add trusted factory
4. Announce new factory support

---

## 🔗 Resources

### Gnosis Safe

- **Interface:** https://app.safe.global/home?safe=base:0x...
- **Docs:** https://docs.safe.global/
- **Support:** https://help.safe.global/

### Base Network

- **Explorer:** https://basescan.org
- **RPC:** https://mainnet.base.org
- **Chain ID:** 8453

### Emergency Contacts

- **Primary:** [To be filled]
- **Secondary:** [To be filled]
- **Discord:** [To be filled]

---

## 📌 Action Items Before Mainnet

**CRITICAL - Must Complete:**

- [ ] **Select 5 signers** with verified identities
- [ ] **Deploy Gnosis Safe** on Base Mainnet
- [ ] **Transfer ownership** from deployer to multisig
- [ ] **Test multisig** with non-critical transaction
- [ ] **Document signers** in this file (table above)
- [ ] **Establish communication** channel for signers
- [ ] **Create emergency** contact protocol

**Estimated Time:** 2 hours (deployment) + coordination time

---

**Last Updated:** October 30, 2025  
**Owner:** Protocol Team  
**Review Schedule:** Monthly or as needed
