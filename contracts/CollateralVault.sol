// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title CollateralVault
 * @notice On-chain collateral locking for the CryptoLend protocol.
 * @dev This contract is OPTIONAL — the MVP runs fully off-chain (custodial).
 *      This demonstrates how the bank could transition to a hybrid on-chain model.
 *
 * Flow:
 *  1. User deposits WBTC into this vault
 *  2. Off-chain system issues loan against locked collateral
 *  3. On liquidation, the owner (bank) can seize collateral
 *  4. On repayment, the owner unlocks collateral for withdrawal
 */
contract CollateralVault is Ownable, ReentrancyGuard {

    // ═══════════════════════════════════════════════════════════════
    // State
    // ═══════════════════════════════════════════════════════════════

    /// @notice ERC-20 token used as collateral (e.g., WBTC)
    IERC20 public immutable collateralToken;

    struct Position {
        uint256 amount;       // Collateral deposited
        uint256 lockedAmount; // Collateral locked against loans
        bool active;
    }

    /// @notice User address => collateral position
    mapping(address => Position) public positions;

    /// @notice Global pause switch (circuit breaker)
    bool public paused;

    // ═══════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event CollateralLocked(address indexed user, uint256 amount);
    event CollateralUnlocked(address indexed user, uint256 amount);
    event CollateralSeized(address indexed user, uint256 amount, string reason);
    event PauseToggled(bool paused);

    // ═══════════════════════════════════════════════════════════════
    // Errors
    // ═══════════════════════════════════════════════════════════════

    error VaultPaused();
    error InsufficientBalance();
    error InsufficientUnlocked();
    error ZeroAmount();
    error PositionNotActive();

    // ═══════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════

    constructor(address _collateralToken) Ownable(msg.sender) {
        collateralToken = IERC20(_collateralToken);
    }

    // ═══════════════════════════════════════════════════════════════
    // Modifiers
    // ═══════════════════════════════════════════════════════════════

    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    // ═══════════════════════════════════════════════════════════════
    // User Functions
    // ═══════════════════════════════════════════════════════════════

    /// @notice Deposit collateral into the vault.
    /// @param amount Amount of collateral tokens to deposit.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        collateralToken.transferFrom(msg.sender, address(this), amount);

        Position storage pos = positions[msg.sender];
        pos.amount += amount;
        pos.active = true;

        emit Deposited(msg.sender, amount);
    }

    /// @notice Withdraw unlocked collateral.
    /// @param amount Amount to withdraw.
    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        Position storage pos = positions[msg.sender];
        if (!pos.active) revert PositionNotActive();

        uint256 unlocked = pos.amount - pos.lockedAmount;
        if (amount > unlocked) revert InsufficientUnlocked();

        pos.amount -= amount;
        if (pos.amount == 0) {
            pos.active = false;
        }

        collateralToken.transfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Get a user's position details.
    function getPosition(address user) external view returns (
        uint256 amount,
        uint256 lockedAmount,
        uint256 availableAmount,
        bool active
    ) {
        Position storage pos = positions[user];
        return (
            pos.amount,
            pos.lockedAmount,
            pos.amount - pos.lockedAmount,
            pos.active
        );
    }

    // ═══════════════════════════════════════════════════════════════
    // Owner (Bank) Functions
    // ═══════════════════════════════════════════════════════════════

    /// @notice Lock collateral when a loan is issued.
    /// @param user The borrower's address.
    /// @param amount Amount to lock.
    function lockCollateral(address user, uint256 amount) external onlyOwner {
        Position storage pos = positions[user];
        if (!pos.active) revert PositionNotActive();

        uint256 unlocked = pos.amount - pos.lockedAmount;
        if (amount > unlocked) revert InsufficientUnlocked();

        pos.lockedAmount += amount;

        emit CollateralLocked(user, amount);
    }

    /// @notice Unlock collateral when a loan is repaid.
    /// @param user The borrower's address.
    /// @param amount Amount to unlock.
    function unlockCollateral(address user, uint256 amount) external onlyOwner {
        Position storage pos = positions[user];
        if (amount > pos.lockedAmount) revert InsufficientBalance();

        pos.lockedAmount -= amount;

        emit CollateralUnlocked(user, amount);
    }

    /// @notice Seize collateral during liquidation.
    /// @param user The borrower's address.
    /// @param amount Amount to seize.
    /// @param reason Description of why collateral was seized.
    function seizeCollateral(
        address user,
        uint256 amount,
        string calldata reason
    ) external onlyOwner nonReentrant {
        Position storage pos = positions[user];
        if (amount > pos.amount) revert InsufficientBalance();

        pos.amount -= amount;
        if (pos.lockedAmount > pos.amount) {
            pos.lockedAmount = pos.amount;
        }
        if (pos.amount == 0) {
            pos.active = false;
        }

        // Transfer seized collateral to bank (owner)
        collateralToken.transfer(owner(), amount);

        emit CollateralSeized(user, amount, reason);
    }

    /// @notice Toggle the global pause (circuit breaker).
    function togglePause() external onlyOwner {
        paused = !paused;
        emit PauseToggled(paused);
    }
}

// ═══════════════════════════════════════════════════════════════════
// Minimal IERC20 interface
// ═══════════════════════════════════════════════════════════════════

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
