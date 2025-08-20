// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Use existing libraries  
import "../libraries/SwapUtilities.sol";

// V3Handler removed - focusing on V2 aggregation only

/**
 * @title QoraFiAggregator
 * @notice Streamlined DEX aggregator with V2 support and direct native swaps
 * @dev Focused on essential aggregation without V3 complexity
 */
contract QoraFiAggregator is AccessControl, ReentrancyGuard, Pausable {
    
    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant AGGREGATOR_MANAGER_ROLE = keccak256("AGGREGATOR_MANAGER_ROLE");

    // --- STRUCTS ---
    struct DEXInfo {
        address routerAddress;
        uint8 dexType; // 0=V2, 2=Custom (V3 handled by separate contract)
        bool isActive;
        uint256 successfulTrades;
        uint256 totalVolume;
    }

    struct TradeRoute {
        bytes32[] dexKeys;
        address[] tokens;
        uint256 expectedOutput;
        uint256 gasEstimate;
    }

    struct AggregatorConfig {
        uint16 maxHops;
        uint16 maxRoutes;
        uint256 minTradeSize;
        uint256 maxSlippage;
        bool enableMultiHop;
        bool enableGasOptimization;
    }

    // --- STATE VARIABLES ---
    mapping(bytes32 => DEXInfo) public dexInfo;
    bytes32[] public activeDEXs;
    
    AggregatorConfig public config;
    address public feeCollector;
    uint16 public aggregatorFeeBps; // Separate fee for aggregation service
    
    // Popular token addresses for path optimization
    address public immutable WBNB;
    address public immutable USDT;
    address[] public commonTokens;

    // --- EVENTS ---
    event DEXAdded(bytes32 indexed key, address indexed router, uint8 dexType);
    event DEXRemoved(bytes32 indexed key);
    event OptimalRouteFound(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 expectedOut);
    event MultiHopTradeExecuted(address indexed user, address[] path, uint256 amountIn, uint256 amountOut);
    event ConfigUpdated(uint16 maxHops, uint16 maxRoutes, bool enableMultiHop);

    // --- ERRORS ---
    error InvalidDEX();
    error RouteNotFound();
    error ExcessiveSlippage();
    error TradeAboveLimit();

    constructor(
        address _wbnb,
        address _usdt, 
        address _feeCollector
    ) {
        require(_wbnb != address(0) && _feeCollector != address(0), "Invalid address");
        
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(AGGREGATOR_MANAGER_ROLE, msg.sender);

        WBNB = _wbnb;
        USDT = _usdt;
        feeCollector = _feeCollector;
        
        // Initialize config
        config = AggregatorConfig({
            maxHops: 4,
            maxRoutes: 10,
            minTradeSize: 0.001 ether,
            maxSlippage: 500, // 5%
            enableMultiHop: true,
            enableGasOptimization: true
        });
        
        aggregatorFeeBps = 10; // 0.1% aggregation fee
        
        
        // Set common tokens for path finding (WBNB and USDT only)
        commonTokens.push(_wbnb);
        commonTokens.push(_usdt);
    }

    // --- AGGREGATION FUNCTIONS ---

    /**
     * @notice Find optimal route across multiple DEXs with multi-hop support
     */
    function findOptimalRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (TradeRoute memory bestRoute) {
        require(amountIn >= config.minTradeSize, "Trade too small");
        
        TradeRoute[] memory routes = new TradeRoute[](config.maxRoutes);
        uint256 routeCount = 0;
        
        // Generate direct routes (single hop)
        routeCount = _generateDirectRoutes(tokenIn, tokenOut, amountIn, routes, routeCount);
        
        // Generate multi-hop routes if enabled
        if (config.enableMultiHop && routeCount < config.maxRoutes) {
            routeCount = _generateMultiHopRoutes(tokenIn, tokenOut, amountIn, routes, routeCount);
        }
        
        // Note: V3 quotes are handled separately in execution functions
        // since quoter functions are not view functions
        
        // Select best route considering output and gas cost
        bestRoute = _selectBestRoute(routes, routeCount, amountIn);
        
        if (bestRoute.expectedOutput == 0) revert RouteNotFound();
    }

    /**
     * @notice Execute optimal multi-hop trade
     */
    function executeOptimalTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "Deadline exceeded");
        
        // Basic size validation
        require(amountIn >= config.minTradeSize, "Trade too small");
        
        // Find optimal route
        TradeRoute memory route = this.findOptimalRoute(tokenIn, tokenOut, amountIn);
        
        emit OptimalRouteFound(tokenIn, tokenOut, amountIn, route.expectedOutput);
        
        // Verify slippage
        uint256 expectedAfterFee = (route.expectedOutput * (10000 - aggregatorFeeBps)) / 10000;
        if (expectedAfterFee < minAmountOut) revert ExcessiveSlippage();
        
        // Transfer input tokens
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        
        // Calculate and collect aggregator fee
        uint256 feeAmount = (amountIn * aggregatorFeeBps) / 10000;
        uint256 tradeAmount = amountIn - feeAmount;
        
        if (feeAmount > 0) {
            IERC20(tokenIn).transfer(feeCollector, feeAmount);
        }
        
        // Execute multi-hop trade
        uint256 finalOutput = _executeMultiHopTrade(route, tradeAmount, deadline);
        
        // Verify minimum output
        require(finalOutput >= minAmountOut, "Insufficient output");
        
        // Transfer output tokens to recipient
        IERC20(tokenOut).transfer(to, finalOutput);
        
        
        emit MultiHopTradeExecuted(msg.sender, route.tokens, tradeAmount, finalOutput);
    }

    /**
     * @notice Execute optimal trade with native BNB input
     */
    function executeOptimalTradeNative(
        address tokenOut,
        uint256 minAmountOut,
        address to,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "Deadline exceeded");
        require(msg.value >= config.minTradeSize, "Trade too small");
        
        // Calculate and collect aggregator fee
        uint256 feeAmount = (msg.value * aggregatorFeeBps) / 10000;
        uint256 tradeAmount = msg.value - feeAmount;
        
        if (feeAmount > 0) {
            (bool success,) = payable(feeCollector).call{value: feeAmount}("");
            require(success, "Fee transfer failed");
        }
        
        // Find optimal route for BNB->Token
        TradeRoute memory route = this.findOptimalRoute(WBNB, tokenOut, tradeAmount);
        
        // Execute using BNB directly
        uint256 finalOutput = _executeNativeToTokenTrade(route, tradeAmount, tokenOut, deadline);
        
        // Verify minimum output
        require(finalOutput >= minAmountOut, "Insufficient output");
        
        // Transfer output tokens to recipient  
        IERC20(tokenOut).transfer(to, finalOutput);
        
        emit MultiHopTradeExecuted(msg.sender, route.tokens, tradeAmount, finalOutput);
    }

    /**
     * @notice Execute optimal trade with native BNB output  
     */
    function executeOptimalTradeToNative(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "Deadline exceeded");
        require(amountIn >= config.minTradeSize, "Trade too small");
        
        // Transfer input tokens
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        
        // Calculate and collect aggregator fee
        uint256 feeAmount = (amountIn * aggregatorFeeBps) / 10000;
        uint256 tradeAmount = amountIn - feeAmount;
        
        if (feeAmount > 0) {
            IERC20(tokenIn).transfer(feeCollector, feeAmount);
        }
        
        // Find optimal route for Token->BNB
        TradeRoute memory route = this.findOptimalRoute(tokenIn, WBNB, tradeAmount);
        
        // Execute swap directly to native BNB (no WBNB wrapping needed)
        uint256 nativeReceived = _executeTokenToNativeTrade(route, tradeAmount, tokenIn, deadline);
        
        // Verify minimum output
        require(nativeReceived >= minAmountOut, "Insufficient output");
        
        // Send BNB to recipient
        (bool success,) = payable(to).call{value: nativeReceived}("");
        require(success, "BNB transfer failed");
        
        emit MultiHopTradeExecuted(msg.sender, route.tokens, tradeAmount, nativeReceived);
    }

    /**
     * @notice Get quote with multi-hop optimization
     */
    function getOptimalQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 gasEstimate) {
        TradeRoute memory route = this.findOptimalRoute(tokenIn, tokenOut, amountIn);
        
        // Apply aggregator fee to quote
        amountOut = (route.expectedOutput * (10000 - aggregatorFeeBps)) / 10000;
        gasEstimate = route.gasEstimate;
    }

    // V3 functions removed - focusing on V2 aggregation only

    // --- INTERNAL FUNCTIONS ---

    function _generateDirectRoutes(
        address tokenIn,
        address tokenOut, 
        uint256 amountIn,
        TradeRoute[] memory routes,
        uint256 routeCount
    ) internal view returns (uint256) {
        uint256 dexCount = activeDEXs.length;
        
        for (uint256 i = 0; i < dexCount && routeCount < config.maxRoutes; i++) {
            bytes32 dexKey = activeDEXs[i];
            DEXInfo storage dex = dexInfo[dexKey];
            
            if (!dex.isActive) continue;
            
            // Handle all active DEX types
            uint256 expectedOut = SwapLib.getExpectedSwapOutput(
                dex.routerAddress,
                tokenIn,
                tokenOut,
                amountIn
            );
            
            if (expectedOut > 0) {
                routes[routeCount] = TradeRoute({
                    dexKeys: _createSingleDEXArray(dexKey),
                    tokens: _createTokenPath(tokenIn, tokenOut),
                    expectedOutput: expectedOut,
                    gasEstimate: _estimateGasCost(1)
                });
                routeCount++;
            }
        }
        
        return routeCount;
    }

    function _generateMultiHopRoutes(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        TradeRoute[] memory routes,
        uint256 routeCount
    ) internal view returns (uint256) {
        if (routeCount >= config.maxRoutes) return routeCount;
        
        // Try multi-hop routes using common intermediate tokens
        address[] memory intermediates = new address[](2);
        intermediates[0] = WBNB;
        intermediates[1] = USDT;
        
        for (uint256 i = 0; i < intermediates.length && routeCount < config.maxRoutes; i++) {
            address intermediate = intermediates[i];
            
            // Skip if intermediate is same as input or output
            if (intermediate == tokenIn || intermediate == tokenOut) continue;
            
            uint256 multiHopOutput = _calculateMultiHopOutput(tokenIn, intermediate, tokenOut, amountIn);
            
            if (multiHopOutput > 0) {
                routes[routeCount] = TradeRoute({
                    dexKeys: new bytes32[](0),
                    tokens: _createMultiHopPath(tokenIn, intermediate, tokenOut),
                    expectedOutput: multiHopOutput,
                    gasEstimate: _estimateGasCost(2)
                });
                routeCount++;
            }
        }
        
        return routeCount;
    }

    function _calculateMultiHopOutput(
        address tokenIn,
        address intermediate,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256) {
        // Find the best output for the first hop (tokenIn -> intermediate)
        // by checking ALL active DEXs.
        uint256 bestIntermediateAmount = 0;
        for (uint i = 0; i < activeDEXs.length; i++) {
             address router = dexInfo[activeDEXs[i]].routerAddress;
             uint256 intermediateAmount = SwapLib.getExpectedSwapOutput(router, tokenIn, intermediate, amountIn);
             if (intermediateAmount > bestIntermediateAmount) {
                 bestIntermediateAmount = intermediateAmount;
             }
        }

        if (bestIntermediateAmount == 0) return 0;

        // Find the best output for the second hop (intermediate -> tokenOut)
        // by checking ALL active DEXs.
        uint256 bestFinalAmount = 0;
        for (uint i = 0; i < activeDEXs.length; i++) {
             address router = dexInfo[activeDEXs[i]].routerAddress;
             uint256 finalAmount = SwapLib.getExpectedSwapOutput(router, intermediate, tokenOut, bestIntermediateAmount);
             if (finalAmount > bestFinalAmount) {
                 bestFinalAmount = finalAmount;
             }
        }

        return bestFinalAmount;
    }

    function _selectBestRoute(
        TradeRoute[] memory routes,
        uint256 routeCount,
        uint256 amountIn
    ) internal view returns (TradeRoute memory bestRoute) {
        uint256 bestScore = 0;
        
        for (uint256 i = 0; i < routeCount; i++) {
            uint256 score = routes[i].expectedOutput;
            
            // Apply gas cost penalty if gas optimization is enabled
            if (config.enableGasOptimization) {
                uint256 gasCostInTokens = _convertGasCostToTokens(routes[i].gasEstimate, amountIn);
                if (score > gasCostInTokens) {
                    score -= gasCostInTokens;
                }
            }
            
            if (score > bestScore) {
                bestScore = score;
                bestRoute = routes[i];
            }
        }
    }

    function _executeMultiHopTrade(
        TradeRoute memory route,
        uint256 amountIn,
        uint256 deadline
    ) internal returns (uint256 finalAmount) {
        // Simplified implementation for multi-hop execution
        // In a full implementation, this would iterate through the route
        // and execute each hop using the appropriate DEX
        
        uint256 currentAmount = amountIn;
        address currentToken = route.tokens[0];
        
        for (uint256 i = 1; i < route.tokens.length; i++) {
            address nextToken = route.tokens[i];
            
            // Find best DEX for this hop (simplified)
            bytes32 bestDEX = activeDEXs[0]; // Use first DEX for now
            address router = dexInfo[bestDEX].routerAddress;
            
            // Execute swap using SwapLib
            currentAmount = SwapLib.executeSwap(
                router,
                currentToken,
                nextToken,
                currentAmount,
                0, // We'll handle slippage at the final step
                deadline
            );
            
            currentToken = nextToken;
            
            // Update DEX statistics
            dexInfo[bestDEX].successfulTrades++;
            dexInfo[bestDEX].totalVolume += currentAmount;
        }
        
        return currentAmount;
    }

    // --- HELPER FUNCTIONS ---

    function _createSingleDEXArray(bytes32 dexKey) internal pure returns (bytes32[] memory) {
        bytes32[] memory result = new bytes32[](1);
        result[0] = dexKey;
        return result;
    }

    function _createTokenPath(address tokenIn, address tokenOut) internal pure returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        return path;
    }

    function _createMultiHopPath(address tokenIn, address intermediate, address tokenOut) internal pure returns (address[] memory) {
        address[] memory path = new address[](3);
        path[0] = tokenIn;
        path[1] = intermediate;
        path[2] = tokenOut;
        return path;
    }

    function _estimateGasCost(uint256 hops) internal pure returns (uint256) {
        // Rough gas estimate based on number of hops
        return 100000 + (hops * 50000); // Base + hop cost
    }

    function _convertGasCostToTokens(uint256 gasEstimate, uint256 amountIn) internal pure returns (uint256) {
        // Convert gas cost to token equivalent (simplified)
        // In reality, this would use gas price and token price oracles
        return (gasEstimate * amountIn) / 1000000; // Rough approximation
    }

    /**
     * @notice Execute native BNB to token trade using SwapLib
     */
    function _executeNativeToTokenTrade(
        TradeRoute memory route,
        uint256 amountIn,
        address tokenOut,
        uint256 deadline
    ) internal returns (uint256 finalAmount) {
        // Find best DEX for this swap
        bytes32 bestDEX = activeDEXs[0]; // Use first DEX for now
        address router = dexInfo[bestDEX].routerAddress;
        
        // Check if multi-hop is needed
        if (route.tokens.length > 2) {
            // Multi-hop: BNB -> USDT -> QOR (direct, no WBNB conversion)
            finalAmount = SwapLib.executeMultiHopETHToTokenSwap(
                router,
                route.tokens, // e.g., [WBNB, USDT, QOR] but WBNB gets replaced with native
                amountIn,
                0, // No minimum for internal calculation
                deadline
            );
        } else {
            // Single hop: BNB -> Token
            finalAmount = SwapLib.executeETHToTokenSwap(
                router,
                tokenOut,
                amountIn,
                0, // No minimum for internal calculation
                deadline
            );
        }
        
        // Update DEX statistics
        dexInfo[bestDEX].successfulTrades++;
        dexInfo[bestDEX].totalVolume += amountIn;
        
        return finalAmount;
    }

    /**
     * @notice Execute token to native BNB trade using SwapLib
     */
    function _executeTokenToNativeTrade(
        TradeRoute memory /* route */,
        uint256 amountIn,
        address tokenIn,
        uint256 deadline
    ) internal returns (uint256 nativeAmount) {
        // Find best DEX for this swap
        bytes32 bestDEX = activeDEXs[0]; // Use first DEX for now
        address router = dexInfo[bestDEX].routerAddress;
        
        // Execute token to ETH swap using SwapLib
        nativeAmount = SwapLib.executeTokenToETHSwap(
            router,
            tokenIn,
            amountIn,
            0, // No minimum for internal calculation
            deadline
        );
        
        // Update DEX statistics
        dexInfo[bestDEX].successfulTrades++;
        dexInfo[bestDEX].totalVolume += amountIn;
        
        return nativeAmount;
    }

    // V3Handler functions removed

    // --- ADMIN FUNCTIONS ---

    function addDEX(
        bytes32 key,
        address routerAddress,
        uint8 dexType
    ) external onlyRole(AGGREGATOR_MANAGER_ROLE) {
        require(routerAddress != address(0), "Invalid router");
        // Accept any DEX type - no longer restricted to V2 only
        if (dexInfo[key].routerAddress != address(0)) revert InvalidDEX();
        
        dexInfo[key] = DEXInfo({
            routerAddress: routerAddress,
            dexType: dexType,
            isActive: true,
            successfulTrades: 0,
            totalVolume: 0
        });
        
        activeDEXs.push(key);
        emit DEXAdded(key, routerAddress, dexType);
    }

    function removeDEX(bytes32 key) external onlyRole(AGGREGATOR_MANAGER_ROLE) {
        if (dexInfo[key].routerAddress == address(0)) revert InvalidDEX();
        
        // Remove from activeDEXs array
        uint256 length = activeDEXs.length;
        for (uint256 i = 0; i < length; i++) {
            if (activeDEXs[i] == key) {
                activeDEXs[i] = activeDEXs[length - 1];
                activeDEXs.pop();
                break;
            }
        }
        
        delete dexInfo[key];
        emit DEXRemoved(key);
    }

    function updateConfig(
        uint16 maxHops,
        uint16 maxRoutes,
        uint256 minTradeSize,
        uint256 maxSlippage,
        bool enableMultiHop,
        bool enableGasOptimization
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(maxHops <= 10 && maxRoutes <= 50, "Invalid limits");
        
        config.maxHops = maxHops;
        config.maxRoutes = maxRoutes;
        config.minTradeSize = minTradeSize;
        config.maxSlippage = maxSlippage;
        config.enableMultiHop = enableMultiHop;
        config.enableGasOptimization = enableGasOptimization;
        
        emit ConfigUpdated(maxHops, maxRoutes, enableMultiHop);
    }

    function setAggregatorFee(uint16 newFeeBps) external onlyRole(GOVERNANCE_ROLE) {
        require(newFeeBps <= 100, "Fee too high"); // Max 1%
        aggregatorFeeBps = newFeeBps;
    }

    function addCommonToken(address token) external onlyRole(GOVERNANCE_ROLE) {
        require(token != address(0), "Invalid token");
        commonTokens.push(token);
    }

    // --- VIEW FUNCTIONS ---

    function getDEXCount() external view returns (uint256) {
        return activeDEXs.length;
    }

    /**
     * @notice Remove token from common tokens list
     */
    function removeCommonToken(uint256 index) external onlyRole(GOVERNANCE_ROLE) {
        require(index < commonTokens.length, "Invalid index");
        commonTokens[index] = commonTokens[commonTokens.length - 1];
        commonTokens.pop();
    }

    /**
     * @notice Get list of common tokens
     */
    function getCommonTokens() external view returns (address[] memory) {
        return commonTokens;
    }

    /**
     * @notice Update DEX status (enable/disable)
     */
    function updateDEXStatus(bytes32 key, bool isActive) external onlyRole(AGGREGATOR_MANAGER_ROLE) {
        require(dexInfo[key].routerAddress != address(0), "DEX does not exist");
        dexInfo[key].isActive = isActive;
    }

    /**
     * @notice Get detailed DEX information
     */
    function getDEXInfo(bytes32 key) external view returns (
        address routerAddress,
        uint8 dexType,
        bool isActive,
        uint256 successfulTrades,
        uint256 totalVolume
    ) {
        DEXInfo storage dex = dexInfo[key];
        return (dex.routerAddress, dex.dexType, dex.isActive, dex.successfulTrades, dex.totalVolume);
    }

    /**
     * @notice Get all DEXs with performance data
     */
    function getAllDEXs() external view returns (
        bytes32[] memory keys,
        address[] memory addresses,
        uint8[] memory dexTypes,
        bool[] memory statuses,
        uint256[] memory successCounts,
        uint256[] memory volumes
    ) {
        uint256 length = activeDEXs.length;
        keys = new bytes32[](length);
        addresses = new address[](length);
        dexTypes = new uint8[](length);
        statuses = new bool[](length);
        successCounts = new uint256[](length);
        volumes = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            bytes32 key = activeDEXs[i];
            DEXInfo storage dex = dexInfo[key];
            keys[i] = key;
            addresses[i] = dex.routerAddress;
            dexTypes[i] = dex.dexType;
            statuses[i] = dex.isActive;
            successCounts[i] = dex.successfulTrades;
            volumes[i] = dex.totalVolume;
        }
    }




    /**
     * @notice Emergency pause function
     */
    function emergencyPause() external onlyRole(GOVERNANCE_ROLE) {
        _pause();
    }

    /**
     * @notice Emergency unpause function
     */
    function emergencyUnpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    // Performance metrics removed to reduce contract size

    /**
     * @notice Recover accidentally sent tokens
     */
    function recoverERC20(address token, uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        IERC20(token).transfer(feeCollector, amount);
    }

    /**
     * @notice Get contract version
     */
    function version() external pure returns (string memory) {
        return "QoraFiAggregator-v1.0.0";
    }

    /**
     * @notice Get current configuration
     */
    function getConfig() external view returns (
        uint16 maxHops,
        uint16 maxRoutes,
        uint256 minTradeSize,
        uint256 maxSlippage,
        bool enableMultiHop,
        bool enableGasOptimization
    ) {
        return (
            config.maxHops,
            config.maxRoutes,
            config.minTradeSize,
            config.maxSlippage,
            config.enableMultiHop,
            config.enableGasOptimization
        );
    }

    /**
     * @notice Allow contract to receive native BNB
     */
    receive() external payable {}
}