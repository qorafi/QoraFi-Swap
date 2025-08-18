// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// Use existing libraries
import "../libraries/SwapUtilities.sol";
import "../libraries/MEVProtection.sol";

// Extended Router Interface for all swap functions
interface IRouterExtended {
    function WETH() external view returns (address);
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory);
    function swapTokensForExactTokens(uint256 amountOut, uint256 amountInMax, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory);
    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory);
    function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory);
    function swapTokensForExactETH(uint256 amountOut, uint256 amountInMax, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory);
}

/**
 * @title QoraFiRouterOptimized 
 * @notice Optimized DEX router using existing libraries for efficiency
 * @dev Uses SwapLib and MEVLib for core functionality
 */
contract QoraFiRouterOptimized is AccessControl, ReentrancyGuard, Pausable {
    
    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ROUTER_MANAGER_ROLE = keccak256("ROUTER_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- STRUCTS ---
    struct RouterData {
        address routerAddress;
        uint32 successCount;
        uint32 failCount;
        bool isActive;
    }

    // --- STATE VARIABLES ---
    mapping(bytes32 => RouterData) public routers;
    mapping(address => bytes32) public routerAddressToKey; // O(1) lookup
    bytes32[] public activeRouterKeys;
    
    address public immutable WBNB;
    address public treasuryWallet;
    uint16 public feePercentBps; // Max 1000 BPS (10%)
    
    // MEV Protection using existing library
    MEVLib.MEVConfig private mevConfig;

    // --- EVENTS ---
    event RouterAdded(bytes32 indexed key, address indexed routerAddress);
    event RouterRemoved(bytes32 indexed key);
    event SwapExecuted(address indexed user, bytes32 indexed routerKey, uint256 amountIn, uint256 amountOut);
    event FeeCollected(address indexed user, address indexed token, uint256 feeAmount);

    // --- ERRORS ---
    error DeadlineExpired();
    error InsufficientOutput();
    error InvalidRouter();
    error RouterExists();
    error NoRoutersAvailable();
    error InvalidFee();

    constructor(
        address _initialRouter,
        address _treasury,
        uint16 _feePercentBps,
        address _wbnb
    ) {
        require(_initialRouter != address(0) && _treasury != address(0), "Invalid address");
        require(_feePercentBps <= 1000, "Fee too high"); // Max 10%

        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(ROUTER_MANAGER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        WBNB = _wbnb;
        treasuryWallet = _treasury;
        feePercentBps = _feePercentBps;

        // Initialize MEV protection
        mevConfig.minDepositInterval = 1; // 1 block minimum
        mevConfig.maxDepositPerBlock = 100 ether; // 100 BNB per block
        mevConfig.maxDepositPerUser = 1000 ether; // 1000 BNB per day per user

        // Add initial router
        bytes32 initialKey = "PancakeV2";
        _addRouter(initialKey, _initialRouter);
    }

    // --- CORE SWAP FUNCTIONS ---

    /**
     * @notice Swap exact BNB for tokens with MEV protection
     */
    function swapExactBNBForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused {
        if (block.timestamp > deadline) revert DeadlineExpired();
        
        // MEV Protection using existing library
        MEVLib.checkPreDeposit(mevConfig, msg.sender, msg.value);
        
        // Find best router and execute
        (bytes32 bestRouterKey, uint256 expectedOut) = _findBestRoute(path, msg.value);
        
        // Calculate fee and amount to swap
        uint256 feeAmount = (msg.value * feePercentBps) / 10000;
        uint256 swapAmount = msg.value - feeAmount;
        
        // Verify expected output after fee
        uint256 expectedAfterFee = (expectedOut * (10000 - feePercentBps)) / 10000;
        if (expectedAfterFee < amountOutMin) revert InsufficientOutput();
        
        // Send fee to treasury
        if (feeAmount > 0) {
            (bool success,) = payable(treasuryWallet).call{value: feeAmount}("");
            require(success, "Fee transfer failed");
            emit FeeCollected(msg.sender, WBNB, feeAmount);
        }
        
        // Execute swap using SwapLib
        address router = routers[bestRouterKey].routerAddress;
        uint256 amountOut = SwapLib.executeETHToTokenSwap(
            router,
            path[path.length - 1],
            swapAmount,
            amountOutMin,
            deadline
        );
        
        // Update MEV and router stats
        MEVLib.updatePostDeposit(mevConfig, msg.sender, msg.value);
        routers[bestRouterKey].successCount++;
        
        // Transfer tokens to recipient
        IERC20(path[path.length - 1]).transfer(to, amountOut);
        
        emit SwapExecuted(msg.sender, bestRouterKey, swapAmount, amountOut);
    }

    /**
     * @notice Swap exact tokens for tokens with MEV protection
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (block.timestamp > deadline) revert DeadlineExpired();
        
        // MEV Protection
        MEVLib.checkPreDeposit(mevConfig, msg.sender, amountIn);
        
        // Find best router
        (bytes32 bestRouterKey, uint256 expectedOut) = _findBestRoute(path, amountIn);
        
        // Transfer tokens and calculate fee
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        
        uint256 feeAmount = (amountIn * feePercentBps) / 10000;
        uint256 swapAmount = amountIn - feeAmount;
        
        // Verify expected output
        uint256 expectedAfterFee = (expectedOut * (10000 - feePercentBps)) / 10000;
        if (expectedAfterFee < amountOutMin) revert InsufficientOutput();
        
        // Send fee to treasury
        if (feeAmount > 0) {
            IERC20(path[0]).transfer(treasuryWallet, feeAmount);
            emit FeeCollected(msg.sender, path[0], feeAmount);
        }
        
        // Execute swap using SwapLib
        address router = routers[bestRouterKey].routerAddress;
        uint256 amountOut = SwapLib.executeSwap(
            router,
            path[0],
            path[path.length - 1],
            swapAmount,
            amountOutMin,
            deadline
        );
        
        // Update stats
        MEVLib.updatePostDeposit(mevConfig, msg.sender, amountIn);
        routers[bestRouterKey].successCount++;
        
        // Transfer output tokens
        IERC20(path[path.length - 1]).transfer(to, amountOut);
        
        emit SwapExecuted(msg.sender, bestRouterKey, swapAmount, amountOut);
    }

    /**
     * @notice Swap tokens for exact amount of output tokens
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (block.timestamp > deadline) revert DeadlineExpired();
        
        // MEV Protection
        MEVLib.checkPreDeposit(mevConfig, msg.sender, amountInMax);
        
        // Find best router and calculate required input
        (bytes32 bestRouterKey, uint256 requiredInput) = _findBestRouteForExactOutput(path, amountOut);
        
        // Apply fee to required input
        uint256 feeAmount = (requiredInput * feePercentBps) / 10000;
        uint256 totalInput = requiredInput + feeAmount;
        
        if (totalInput > amountInMax) revert InsufficientOutput();
        
        // Transfer tokens
        IERC20(path[0]).transferFrom(msg.sender, address(this), totalInput);
        
        // Send fee to treasury
        if (feeAmount > 0) {
            IERC20(path[0]).transfer(treasuryWallet, feeAmount);
            emit FeeCollected(msg.sender, path[0], feeAmount);
        }
        
        // Execute swap
        address router = routers[bestRouterKey].routerAddress;
        IERC20(path[0]).approve(router, requiredInput);
        
        try IRouterExtended(router).swapTokensForExactTokens(amountOut, requiredInput, path, to, deadline) {
            routers[bestRouterKey].successCount++;
            MEVLib.updatePostDeposit(mevConfig, msg.sender, totalInput);
            emit SwapExecuted(msg.sender, bestRouterKey, requiredInput, amountOut);
        } catch {
            revert("Swap failed");
        }
    }

    /**
     * @notice Swap BNB for exact amount of tokens
     */
    function swapBNBForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused {
        if (block.timestamp > deadline) revert DeadlineExpired();
        
        // MEV Protection
        MEVLib.checkPreDeposit(mevConfig, msg.sender, msg.value);
        
        // Find best router and calculate required BNB
        (bytes32 bestRouterKey, uint256 requiredBNB) = _findBestRouteForExactOutput(path, amountOut);
        
        // Apply fee
        uint256 feeAmount = (requiredBNB * feePercentBps) / 10000;
        uint256 totalRequired = requiredBNB + feeAmount;
        
        if (totalRequired > msg.value) revert InsufficientOutput();
        
        // Send fee to treasury
        if (feeAmount > 0) {
            (bool success,) = payable(treasuryWallet).call{value: feeAmount}("");
            require(success, "Fee transfer failed");
            emit FeeCollected(msg.sender, WBNB, feeAmount);
        }
        
        // Execute swap
        address router = routers[bestRouterKey].routerAddress;
        try IRouterExtended(router).swapETHForExactTokens{value: requiredBNB}(amountOut, path, to, deadline) {
            routers[bestRouterKey].successCount++;
            MEVLib.updatePostDeposit(mevConfig, msg.sender, msg.value);
            emit SwapExecuted(msg.sender, bestRouterKey, requiredBNB, amountOut);
            
            // Refund excess BNB
            uint256 refund = msg.value - totalRequired;
            if (refund > 0) {
                (bool refundSuccess,) = payable(msg.sender).call{value: refund}("");
                require(refundSuccess, "Refund failed");
            }
        } catch {
            revert("Swap failed");
        }
    }

    /**
     * @notice Swap exact tokens for BNB
     */
    function swapExactTokensForBNB(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (block.timestamp > deadline) revert DeadlineExpired();
        
        // MEV Protection
        MEVLib.checkPreDeposit(mevConfig, msg.sender, amountIn);
        
        // Find best router
        (bytes32 bestRouterKey, uint256 expectedOut) = _findBestRoute(path, amountIn);
        
        // Calculate fee and amount to swap
        uint256 feeAmount = (amountIn * feePercentBps) / 10000;
        uint256 swapAmount = amountIn - feeAmount;
        
        // Verify expected output after fee
        uint256 expectedAfterFee = (expectedOut * (10000 - feePercentBps)) / 10000;
        if (expectedAfterFee < amountOutMin) revert InsufficientOutput();
        
        // Transfer tokens
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        
        // Send fee to treasury
        if (feeAmount > 0) {
            IERC20(path[0]).transfer(treasuryWallet, feeAmount);
            emit FeeCollected(msg.sender, path[0], feeAmount);
        }
        
        // Execute swap
        address router = routers[bestRouterKey].routerAddress;
        IERC20(path[0]).approve(router, swapAmount);
        
        try IRouterExtended(router).swapExactTokensForETH(swapAmount, amountOutMin, path, to, deadline) returns (uint256[] memory amounts) {
            routers[bestRouterKey].successCount++;
            MEVLib.updatePostDeposit(mevConfig, msg.sender, amountIn);
            emit SwapExecuted(msg.sender, bestRouterKey, swapAmount, amounts[amounts.length - 1]);
        } catch {
            revert("Swap failed");
        }
    }

    /**
     * @notice Swap tokens for exact BNB
     */
    function swapTokensForExactBNB(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        if (block.timestamp > deadline) revert DeadlineExpired();
        
        // MEV Protection
        MEVLib.checkPreDeposit(mevConfig, msg.sender, amountInMax);
        
        // Find best router and calculate required input
        (bytes32 bestRouterKey, uint256 requiredInput) = _findBestRouteForExactOutput(path, amountOut);
        
        // Apply fee
        uint256 feeAmount = (requiredInput * feePercentBps) / 10000;
        uint256 totalInput = requiredInput + feeAmount;
        
        if (totalInput > amountInMax) revert InsufficientOutput();
        
        // Transfer tokens
        IERC20(path[0]).transferFrom(msg.sender, address(this), totalInput);
        
        // Send fee to treasury
        if (feeAmount > 0) {
            IERC20(path[0]).transfer(treasuryWallet, feeAmount);
            emit FeeCollected(msg.sender, path[0], feeAmount);
        }
        
        // Execute swap
        address router = routers[bestRouterKey].routerAddress;
        IERC20(path[0]).approve(router, requiredInput);
        
        try IRouterExtended(router).swapTokensForExactETH(amountOut, requiredInput, path, to, deadline) {
            routers[bestRouterKey].successCount++;
            MEVLib.updatePostDeposit(mevConfig, msg.sender, totalInput);
            emit SwapExecuted(msg.sender, bestRouterKey, requiredInput, amountOut);
        } catch {
            revert("Swap failed");
        }
    }

    // --- ROUTER MANAGEMENT ---

    function addRouter(bytes32 key, address routerAddress) external onlyRole(ROUTER_MANAGER_ROLE) {
        _addRouter(key, routerAddress);
    }

    function _addRouter(bytes32 key, address routerAddress) internal {
        if (routerAddress == address(0)) revert InvalidRouter();
        if (routers[key].routerAddress != address(0)) revert RouterExists();
        
        routers[key] = RouterData({
            routerAddress: routerAddress,
            successCount: 0,
            failCount: 0,
            isActive: true
        });
        
        routerAddressToKey[routerAddress] = key;
        activeRouterKeys.push(key);
        
        emit RouterAdded(key, routerAddress);
    }

    function removeRouter(bytes32 key) external onlyRole(ROUTER_MANAGER_ROLE) {
        address routerAddr = routers[key].routerAddress;
        if (routerAddr == address(0)) revert InvalidRouter();
        
        // Remove from activeRouterKeys array
        uint256 length = activeRouterKeys.length;
        for (uint256 i = 0; i < length; i++) {
            if (activeRouterKeys[i] == key) {
                activeRouterKeys[i] = activeRouterKeys[length - 1];
                activeRouterKeys.pop();
                break;
            }
        }
        
        delete routerAddressToKey[routerAddr];
        delete routers[key];
        
        emit RouterRemoved(key);
    }

    // --- VIEW FUNCTIONS ---

    /**
     * @notice Find best route using optimized O(1) lookups
     */
    function _findBestRoute(address[] calldata path, uint256 amountIn) 
        internal view returns (bytes32 bestKey, uint256 bestAmountOut) 
    {
        uint256 length = activeRouterKeys.length;
        if (length == 0) revert NoRoutersAvailable();
        
        for (uint256 i = 0; i < length; i++) {
            bytes32 key = activeRouterKeys[i];
            RouterData storage routerData = routers[key];
            
            if (!routerData.isActive) continue;
            
            uint256 expectedOut = SwapLib.getExpectedSwapOutput(
                routerData.routerAddress,
                path[0],
                path[path.length - 1],
                amountIn
            );
            
            if (expectedOut > bestAmountOut) {
                bestAmountOut = expectedOut;
                bestKey = key;
            }
        }
        
        if (bestAmountOut == 0) revert NoRoutersAvailable();
    }

    function getQuote(address[] calldata path, uint256 amountIn) 
        external view returns (uint256 amountOut) 
    {
        (, amountOut) = _findBestRoute(path, amountIn);
        // Apply fee to quote
        amountOut = (amountOut * (10000 - feePercentBps)) / 10000;
    }

    function getUserMEVStatus(address user) external view returns (
        uint256 lastBlock,
        uint256 blocksSince,
        bool canSwap,
        uint256 dailyUsed,
        uint256 dailyRemaining
    ) {
        return MEVLib.getUserStatus(mevConfig, user);
    }

    // --- GOVERNANCE FUNCTIONS ---

    function setPaused(bool paused) external onlyRole(PAUSER_ROLE) {
        if (paused) _pause(); 
        else _unpause();
    }

    function setTreasuryWallet(address newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        require(newTreasury != address(0), "Invalid treasury");
        treasuryWallet = newTreasury;
    }

    function setFeePercent(uint16 newFeePercentBps) external onlyRole(GOVERNANCE_ROLE) {
        if (newFeePercentBps > 1000) revert InvalidFee(); // Max 10%
        feePercentBps = newFeePercentBps;
    }

    function updateMEVConfig(
        uint256 minInterval,
        uint256 maxPerBlock,
        uint256 maxPerUser
    ) external onlyRole(GOVERNANCE_ROLE) {
        mevConfig.minDepositInterval = minInterval;
        mevConfig.maxDepositPerBlock = maxPerBlock;
        mevConfig.maxDepositPerUser = maxPerUser;
    }

    // --- EMERGENCY FUNCTIONS ---

    function emergencyWithdraw(address token) external onlyRole(GOVERNANCE_ROLE) {
        if (token == address(0)) {
            payable(treasuryWallet).transfer(address(this).balance);
        } else {
            IERC20 tokenContract = IERC20(token);
            tokenContract.transfer(treasuryWallet, tokenContract.balanceOf(address(this)));
        }
    }

    function getRouterCount() external view returns (uint256) {
        return activeRouterKeys.length;
    }

    /**
     * @notice Get amounts out for a swap path
     */
    function getAmountsOut(uint256 amountIn, address[] calldata path) 
        external view returns (uint256[] memory amounts) 
    {
        (, uint256 bestAmountOut) = _findBestRoute(path, amountIn);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = bestAmountOut;
    }

    /**
     * @notice Get amounts in required for desired output
     */
    function getAmountsIn(uint256 amountOut, address[] calldata path) 
        external view returns (uint256[] memory amounts) 
    {
        (, uint256 requiredIn) = _findBestRouteForExactOutput(path, amountOut);
        amounts = new uint256[](2);
        amounts[0] = requiredIn;
        amounts[1] = amountOut;
    }

    /**
     * @notice Toggle router active status
     */
    function toggleRouterStatus(bytes32 key) external onlyRole(ROUTER_MANAGER_ROLE) {
        require(routers[key].routerAddress != address(0), "Router does not exist");
        routers[key].isActive = !routers[key].isActive;
    }

    /**
     * @notice Get detailed router information
     */
    function getRouterInfo(bytes32 key) external view returns (
        address routerAddress,
        uint32 successCount,
        uint32 failCount,
        bool isActive
    ) {
        RouterData storage router = routers[key];
        return (router.routerAddress, router.successCount, router.failCount, router.isActive);
    }

    /**
     * @notice Get all active routers with stats
     */
    function getAllRouters() external view returns (
        bytes32[] memory keys,
        address[] memory addresses,
        uint32[] memory successCounts,
        bool[] memory statuses
    ) {
        uint256 length = activeRouterKeys.length;
        keys = new bytes32[](length);
        addresses = new address[](length);
        successCounts = new uint32[](length);
        statuses = new bool[](length);
        
        for (uint256 i = 0; i < length; i++) {
            bytes32 key = activeRouterKeys[i];
            RouterData storage router = routers[key];
            keys[i] = key;
            addresses[i] = router.routerAddress;
            successCounts[i] = router.successCount;
            statuses[i] = router.isActive;
        }
    }

    /**
     * @notice Get contract version
     */
    function version() external pure returns (string memory) {
        return "QoraFiRouter-v1.0.0";
    }

    /**
     * @notice Check if interface is supported
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @notice Get total fees collected (view only - fees are sent directly to treasury)
     * @dev Fees are sent directly to treasuryWallet on each swap
     */
    function getTreasuryWallet() external view returns (address) {
        return treasuryWallet;
    }

    /**
     * @notice Get current fee percentage in basis points
     */
    function getCurrentFeePercent() external view returns (uint16) {
        return feePercentBps;
    }

    // --- INTERNAL HELPER FUNCTIONS ---

    /**
     * @notice Find best route for exact output amount
     */
    function _findBestRouteForExactOutput(address[] calldata path, uint256 amountOut) 
        internal view returns (bytes32 bestKey, uint256 bestAmountIn) 
    {
        uint256 length = activeRouterKeys.length;
        if (length == 0) revert NoRoutersAvailable();
        
        bestAmountIn = type(uint256).max; // Start with max value
        
        for (uint256 i = 0; i < length; i++) {
            bytes32 key = activeRouterKeys[i];
            RouterData storage routerData = routers[key];
            
            if (!routerData.isActive) continue;
            
            try IRouterExtended(routerData.routerAddress).getAmountsIn(amountOut, path) returns (uint256[] memory amounts) {
                uint256 requiredIn = amounts[0];
                if (requiredIn < bestAmountIn && requiredIn > 0) {
                    bestAmountIn = requiredIn;
                    bestKey = key;
                }
            } catch {
                continue;
            }
        }
        
        if (bestAmountIn == type(uint256).max) revert NoRoutersAvailable();
    }

    receive() external payable {}
}