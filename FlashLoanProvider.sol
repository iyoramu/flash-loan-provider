// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title Advanced Flash Loan Provider
 * @dev Uncollateralized flash loan implementation with premium calculations, whitelisting,
 * and risk management features. Designed for high-performance DeFi applications.
 */
contract FlashLoanProvider is Ownable, ReentrancyGuard {
    // Loan parameters structure
    struct LoanParams {
        uint256 maxLoanAmount;
        uint256 minLoanAmount;
        uint256 basePremium; // basis points (1 = 0.01%)
        uint256 dynamicPremiumRate; // basis points per ETH
        uint256 maxLoanDuration;
    }

    // Token whitelist mapping
    mapping(address => bool) public whitelistedTokens;
    
    // Loan parameters for each token
    mapping(address => LoanParams) public tokenParams;
    
    // User whitelist
    mapping(address => bool) public whitelistedUsers;
    
    // Total fees collected
    mapping(address => uint256) public totalFeesCollected;
    
    // Loan statistics
    mapping(address => uint256) public totalLoansVolume;
    mapping(address => uint256) public totalLoansCount;
    
    // Events
    event FlashLoanExecuted(
        address indexed borrower,
        address indexed token,
        uint256 amount,
        uint256 premium,
        uint256 timestamp
    );
    event TokenWhitelisted(address indexed token, LoanParams params);
    event TokenRemoved(address indexed token);
    event UserWhitelisted(address indexed user);
    event UserRemoved(address indexed user);
    event FeesWithdrawn(address indexed token, uint256 amount);
    event LoanParamsUpdated(address indexed token, LoanParams params);

    /**
     * @dev Initializes the contract with owner and initial whitelisted tokens
     * @param initialTokens List of tokens to whitelist initially
     * @param initialParams List of loan parameters for each token
     */
    constructor(
        address[] memory initialTokens,
        LoanParams[] memory initialParams
    ) {
        require(initialTokens.length == initialParams.length, "Mismatched arrays");
        
        for (uint256 i = 0; i < initialTokens.length; i++) {
            _whitelistToken(initialTokens[i], initialParams[i]);
        }
    }

    /**
     * @dev Executes a flash loan
     * @param token The loan currency
     * @param amount The amount of tokens to borrow
     * @param data Arbitrary data to pass to the receiver
     */
    function executeFlashLoan(
        address token,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant {
        require(whitelistedTokens[token], "Token not whitelisted");
        require(whitelistedUsers[msg.sender], "User not whitelisted");
        
        LoanParams memory params = tokenParams[token];
        require(amount >= params.minLoanAmount, "Amount below minimum");
        require(amount <= params.maxLoanAmount, "Amount exceeds maximum");
        
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        require(balanceBefore >= amount, "Insufficient liquidity");
        
        // Calculate premium (base + dynamic based on amount)
        uint256 premium = calculatePremium(token, amount);
        
        // Transfer tokens to borrower
        IERC20(token).transfer(msg.sender, amount);
        
        // Execute borrower's operation
        IFlashLoanReceiver(msg.sender).executeOperation(
            token,
            amount,
            premium,
            data
        );
        
        // Verify repayment
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        require(
            balanceAfter >= balanceBefore + premium,
            "Flash loan not repaid"
        );
        
        // Update statistics
        totalLoansVolume[token] += amount;
        totalLoansCount[token] += 1;
        totalFeesCollected[token] += premium;
        
        emit FlashLoanExecuted(msg.sender, token, amount, premium, block.timestamp);
    }

    /**
     * @dev Calculates the premium for a flash loan
     * @param token The loan currency
     * @param amount The amount of tokens to borrow
     * @return premium The calculated premium
     */
    function calculatePremium(
        address token,
        uint256 amount
    ) public view returns (uint256 premium) {
        LoanParams memory params = tokenParams[token];
        premium = params.basePremium * amount / 10000; // base premium in basis points
        
        // Add dynamic premium based on amount
        uint256 dynamicPremium = params.dynamicPremiumRate * amount / 10000;
        premium += dynamicPremium;
        
        return premium;
    }

    /**
     * @dev Whitelists a token and sets its loan parameters
     * @param token The token to whitelist
     * @param params The loan parameters for this token
     */
    function whitelistToken(
        address token,
        LoanParams memory params
    ) external onlyOwner {
        _whitelistToken(token, params);
    }

    function _whitelistToken(
        address token,
        LoanParams memory params
    ) internal {
        require(token != address(0), "Invalid token address");
        require(params.maxLoanAmount > 0, "Invalid max loan amount");
        require(params.minLoanAmount <= params.maxLoanAmount, "Invalid min amount");
        require(params.basePremium <= 10000, "Premium too high"); // Max 100%
        
        whitelistedTokens[token] = true;
        tokenParams[token] = params;
        
        emit TokenWhitelisted(token, params);
    }

    /**
     * @dev Removes a token from the whitelist
     * @param token The token to remove
     */
    function removeToken(address token) external onlyOwner {
        require(whitelistedTokens[token], "Token not whitelisted");
        
        whitelistedTokens[token] = false;
        delete tokenParams[token];
        
        emit TokenRemoved(token);
    }

    /**
     * @dev Updates loan parameters for a whitelisted token
     * @param token The token to update
     * @param params The new loan parameters
     */
    function updateLoanParams(
        address token,
        LoanParams memory params
    ) external onlyOwner {
        require(whitelistedTokens[token], "Token not whitelisted");
        require(params.maxLoanAmount > 0, "Invalid max loan amount");
        require(params.minLoanAmount <= params.maxLoanAmount, "Invalid min amount");
        require(params.basePremium <= 10000, "Premium too high"); // Max 100%
        
        tokenParams[token] = params;
        
        emit LoanParamsUpdated(token, params);
    }

    /**
     * @dev Whitelists a user to access flash loans
     * @param user The user to whitelist
     */
    function whitelistUser(address user) external onlyOwner {
        require(user != address(0), "Invalid user address");
        
        whitelistedUsers[user] = true;
        
        emit UserWhitelisted(user);
    }

    /**
     * @dev Removes a user from the whitelist
     * @param user The user to remove
     */
    function removeUser(address user) external onlyOwner {
        require(whitelistedUsers[user], "User not whitelisted");
        
        whitelistedUsers[user] = false;
        
        emit UserRemoved(user);
    }

    /**
     * @dev Withdraws collected fees to owner
     * @param token The token to withdraw fees from
     */
    function withdrawFees(address token) external onlyOwner {
        uint256 amount = totalFeesCollected[token];
        require(amount > 0, "No fees to withdraw");
        
        totalFeesCollected[token] = 0;
        IERC20(token).transfer(owner(), amount);
        
        emit FeesWithdrawn(token, amount);
    }

    /**
     * @dev Deposits liquidity into the contract
     * @param token The token to deposit
     * @param amount The amount to deposit
     */
    function depositLiquidity(address token, uint256 amount) external {
        require(whitelistedTokens[token], "Token not whitelisted");
        require(amount > 0, "Amount must be positive");
        
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev Withdraws liquidity from the contract (owner only)
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     */
    function withdrawLiquidity(address token, uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be positive");
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 available = balance - totalFeesCollected[token];
        require(amount <= available, "Insufficient available liquidity");
        
        IERC20(token).transfer(owner(), amount);
    }

    /**
     * @dev Returns the available liquidity for a token
     * @param token The token to check
     * @return available Available liquidity (total balance minus collected fees)
     */
    function getAvailableLiquidity(address token) external view returns (uint256 available) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        available = balance - totalFeesCollected[token];
    }
}

/**
 * @title Flash Loan Receiver Interface
 * @dev Contracts must implement this to receive flash loans
 */
interface IFlashLoanReceiver {
    function executeOperation(
        address token,
        uint256 amount,
        uint256 premium,
        bytes calldata data
    ) external returns (bool);
}
