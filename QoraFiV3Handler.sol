// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// --- V3 INTERFACES ---

interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

interface IPancakeV3Quoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}

/**
 * @title QoraFiV3Handler
 * @notice Separate contract to handle V3 DEX operations and reduce main aggregator size
 * @dev Handles PancakeSwap V3, Uniswap V3, and other concentrated liquidity DEXs
 */
contract QoraFiV3Handler is AccessControl, ReentrancyGuard {
    
    // --- ROLES ---
    bytes32 public constant AGGREGATOR_ROLE = keccak256("AGGREGATOR_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;


    // --- STRUCTS ---
    
    struct V3DEXInfo {
        address routerAddress;
        address quoterAddress;
        uint24[] supportedFees;
        bool isActive;
        uint256 successfulTrades;
        string name;
    }

    struct V3Quote {
        uint256 amountOut;
        uint24 fee;
        uint256 gasEstimate;
        bool isValid;
    }

    // --- STATE VARIABLES ---
    
    mapping(bytes32 => V3DEXInfo) public v3DEXs;
    bytes32[] public activeV3DEXs;
    
    // Common V3 fee tiers
    uint24[] public commonFees = [500, 3000, 10000]; // 0.05%, 0.3%, 1%
    
    // Network addresses
    address public immutable WBNB;
    
    // --- EVENTS ---
    
    event V3DEXAdded(bytes32 indexed key, address indexed router, address indexed quoter);
    event V3DEXRemoved(bytes32 indexed key);
    event V3TradeExecuted(bytes32 indexed dexKey, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint24 fee);

    // --- ERRORS ---
    
    error V3DEXNotFound();
    error V3DEXAlreadyExists();
    error InvalidV3Router();
    error V3TradeFailure();
    error OnlyAggregator();

    constructor(address _wbnb) {
        require(_wbnb != address(0), "Invalid WBNB address");
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(AGGREGATOR_ROLE, msg.sender);
        WBNB = _wbnb;
    }

    modifier onlyAggregator() {
        if (!hasRole(AGGREGATOR_ROLE, msg.sender)) revert OnlyAggregator();
        _;
    }

    // --- V3 DEX MANAGEMENT ---

    /**
     * @notice Add V3 DEX with quoter
     */
    function addV3DEX(
        bytes32 key,
        address routerAddress,
        address quoterAddress,
        uint24[] calldata supportedFees,
        string calldata name
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (routerAddress == address(0) || quoterAddress == address(0)) revert InvalidV3Router();
        if (v3DEXs[key].routerAddress != address(0)) revert V3DEXAlreadyExists();
        
        v3DEXs[key] = V3DEXInfo({
            routerAddress: routerAddress,
            quoterAddress: quoterAddress,
            supportedFees: supportedFees,
            isActive: true,
            successfulTrades: 0,
            name: name
        });
        
        activeV3DEXs.push(key);
        emit V3DEXAdded(key, routerAddress, quoterAddress);
    }

    /**
     * @notice Remove V3 DEX
     */
    function removeV3DEX(bytes32 key) external onlyRole(GOVERNANCE_ROLE) {
        if (v3DEXs[key].routerAddress == address(0)) revert V3DEXNotFound();
        
        // Remove from active array
        uint256 length = activeV3DEXs.length;
        for (uint256 i = 0; i < length; i++) {
            if (activeV3DEXs[i] == key) {
                activeV3DEXs[i] = activeV3DEXs[length - 1];
                activeV3DEXs.pop();
                break;
            }
        }
        
        delete v3DEXs[key];
        emit V3DEXRemoved(key);
    }

    /**
     * @notice Toggle V3 DEX status
     */
    function toggleV3DEXStatus(bytes32 key) external onlyRole(GOVERNANCE_ROLE) {
        if (v3DEXs[key].routerAddress == address(0)) revert V3DEXNotFound();
        v3DEXs[key].isActive = !v3DEXs[key].isActive;
    }

    // --- V3 QUOTE FUNCTIONS ---

    /**
     * @notice Get best V3 quote across all DEXs and fee tiers
     */
    function getBestV3Quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external onlyAggregator returns (V3Quote memory bestQuote) {
        uint256 dexCount = activeV3DEXs.length;
        
        for (uint256 i = 0; i < dexCount; i++) {
            bytes32 dexKey = activeV3DEXs[i];
            V3DEXInfo storage dex = v3DEXs[dexKey];
            
            if (!dex.isActive) continue;
            
            // Try all supported fee tiers
            for (uint256 j = 0; j < dex.supportedFees.length; j++) {
                uint24 fee = dex.supportedFees[j];
                
                try IPancakeV3Quoter(dex.quoterAddress).quoteExactInputSingle(
                    tokenIn,
                    tokenOut,
                    fee,
                    amountIn,
                    0 // No price limit
                ) returns (uint256 amountOut) {
                    if (amountOut > bestQuote.amountOut) {
                        bestQuote = V3Quote({
                            amountOut: amountOut,
                            fee: fee,
                            gasEstimate: _estimateV3Gas(1),
                            isValid: true
                        });
                    }
                } catch {
                    continue; // Try next fee tier
                }
            }
        }
    }

    /**
     * @notice Get quotes from specific V3 DEX
     */
    function getV3QuoteFromDEX(
        bytes32 dexKey,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external onlyAggregator returns (V3Quote[] memory quotes) {
        V3DEXInfo storage dex = v3DEXs[dexKey];
        if (dex.routerAddress == address(0) || !dex.isActive) {
            return quotes;
        }
        
        quotes = new V3Quote[](dex.supportedFees.length);
        
        for (uint256 i = 0; i < dex.supportedFees.length; i++) {
            uint24 fee = dex.supportedFees[i];
            
            try IPancakeV3Quoter(dex.quoterAddress).quoteExactInputSingle(
                tokenIn,
                tokenOut,
                fee,
                amountIn,
                0
            ) returns (uint256 amountOut) {
                quotes[i] = V3Quote({
                    amountOut: amountOut,
                    fee: fee,
                    gasEstimate: _estimateV3Gas(1),
                    isValid: true
                });
            } catch {
                quotes[i] = V3Quote({
                    amountOut: 0,
                    fee: fee,
                    gasEstimate: 0,
                    isValid: false
                });
            }
        }
    }

    // --- V3 EXECUTION FUNCTIONS ---

    /**
     * @notice Execute V3 swap
     */
    function executeV3Swap(
        bytes32 dexKey,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external onlyAggregator nonReentrant returns (uint256 amountOut) {
        V3DEXInfo storage dex = v3DEXs[dexKey];
        if (dex.routerAddress == address(0) || !dex.isActive) revert V3DEXNotFound();
        
        // Prepare parameters
        IPancakeV3Router.ExactInputSingleParams memory params = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });
        
        // Execute swap
        try IPancakeV3Router(dex.routerAddress).exactInputSingle(params) returns (uint256 result) {
            amountOut = result;
            dex.successfulTrades++;
            emit V3TradeExecuted(dexKey, tokenIn, tokenOut, amountIn, amountOut, fee);
        } catch {
            revert V3TradeFailure();
        }
    }

    /**
     * @notice Execute V3 swap with ETH
     */
    function executeV3SwapETH(
        bytes32 dexKey,
        address tokenOut,
        uint24 fee,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external payable onlyAggregator nonReentrant returns (uint256 amountOut) {
        V3DEXInfo storage dex = v3DEXs[dexKey];
        if (dex.routerAddress == address(0) || !dex.isActive) revert V3DEXNotFound();
        
        // For ETH swaps, tokenIn would be WBNB
        address wbnbAddress = WBNB;
        
        IPancakeV3Router.ExactInputSingleParams memory params = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: wbnbAddress,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            deadline: deadline,
            amountIn: msg.value,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });
        
        try IPancakeV3Router(dex.routerAddress).exactInputSingle{value: msg.value}(params) returns (uint256 result) {
            amountOut = result;
            dex.successfulTrades++;
            emit V3TradeExecuted(dexKey, wbnbAddress, tokenOut, msg.value, amountOut, fee);
        } catch {
            revert V3TradeFailure();
        }
    }

    // --- VIEW FUNCTIONS ---

    /**
     * @notice Get V3 DEX information
     */
    function getV3DEXInfo(bytes32 key) external view returns (
        address routerAddress,
        address quoterAddress,
        uint24[] memory supportedFees,
        bool isActive,
        uint256 successfulTrades,
        string memory name
    ) {
        V3DEXInfo storage dex = v3DEXs[key];
        return (dex.routerAddress, dex.quoterAddress, dex.supportedFees, dex.isActive, dex.successfulTrades, dex.name);
    }

    /**
     * @notice Get all active V3 DEXs
     */
    function getAllV3DEXs() external view returns (
        bytes32[] memory keys,
        address[] memory routers,
        address[] memory quoters,
        bool[] memory statuses,
        string[] memory names
    ) {
        uint256 length = activeV3DEXs.length;
        keys = new bytes32[](length);
        routers = new address[](length);
        quoters = new address[](length);
        statuses = new bool[](length);
        names = new string[](length);
        
        for (uint256 i = 0; i < length; i++) {
            bytes32 key = activeV3DEXs[i];
            V3DEXInfo storage dex = v3DEXs[key];
            keys[i] = key;
            routers[i] = dex.routerAddress;
            quoters[i] = dex.quoterAddress;
            statuses[i] = dex.isActive;
            names[i] = dex.name;
        }
    }

    /**
     * @notice Get V3 DEX count
     */
    function getV3DEXCount() external view returns (uint256) {
        return activeV3DEXs.length;
    }

    /**
     * @notice Get common fee tiers
     */
    function getCommonFees() external view returns (uint24[] memory) {
        return commonFees;
    }

    // --- INTERNAL FUNCTIONS ---

    function _estimateV3Gas(uint256 hops) internal pure returns (uint256) {
        // V3 swaps use more gas than V2
        return 150000 + (hops * 75000);
    }


    // --- ADMIN FUNCTIONS ---

    /**
     * @notice Add common fee tier
     */
    function addCommonFee(uint24 fee) external onlyRole(GOVERNANCE_ROLE) {
        commonFees.push(fee);
    }

    /**
     * @notice Remove common fee tier
     */
    function removeCommonFee(uint256 index) external onlyRole(GOVERNANCE_ROLE) {
        require(index < commonFees.length, "Invalid index");
        commonFees[index] = commonFees[commonFees.length - 1];
        commonFees.pop();
    }

    /**
     * @notice Emergency withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        if (token == address(0)) {
            payable(msg.sender).transfer(amount);
        } else {
            IERC20(token).transfer(msg.sender, amount);
        }
    }

    /**
     * @notice Get contract version
     */
    function version() external pure returns (string memory) {
        return "QoraFiV3Handler-v1.0.0";
    }

    receive() external payable {}
}