// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {DepositTimelock} from "src/DepositTimelock.sol";
import {EscrowTimelock} from "src/EscrowTimelock.sol";
import {CollateralTimelock} from "src/CollateralTimelock.sol";

import {TestERC721} from "./mocks/TestERC721.sol";

/**
 * @title Base test setup
 * @author USD.AI Foundation
 */
abstract contract BaseTest is Test {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    /* Arbitrum Mainnet addresses */
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address internal constant USDAI = 0x0A1a1A107E45b7Ced86833863f482BC5f4ed82EF;
    address internal constant STAKED_USDAI = 0x0B2b2B2076d95dda7817e785989fE353fe955ef9;
    address internal constant UNISWAP_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    /* Rate constants (per second, scaled by 1e18). Each scales linearly from RATE_10_PCT for consistency. */
    uint256 internal constant RATE_8_PCT = 2536783359;
    uint256 internal constant RATE_8_5_PCT = 2695332319;
    uint256 internal constant RATE_9_PCT = 2853881279;
    uint256 internal constant RATE_10_PCT = 3170979199;
    uint256 internal constant RATE_12_PCT = 3805175039;
    uint256 internal constant RATE_14_PCT = 4439370878;

    /* Fixed point scale */
    uint256 internal constant FIXED_POINT_SCALE = 1e18;

    /* Maximum per-second escrow timelock rate, 100% APR over a 365 day year */
    uint256 internal constant MAX_ESCROW_INTEREST_RATE = 31_709_791_983;

    /* Maximum per-second interest rate, 100% APR over a 365 day year */
    uint256 internal constant MAX_INTEREST_RATE = 31_709_791_983;

    /*------------------------------------------------------------------------*/
    /* User accounts */
    /*------------------------------------------------------------------------*/

    struct Users {
        address payable deployer;
        address payable admin;
        address payable feeRecipient;
        address payable borrower;
        address payable lender1;
        address payable lender2;
        address payable lender3;
        address payable liquidator;
    }

    Users internal users;

    /*------------------------------------------------------------------------*/
    /* Contract instances */
    /*------------------------------------------------------------------------*/

    DepositTimelock internal depositTimelockImpl;
    DepositTimelock internal depositTimelock;
    TransparentUpgradeableProxy internal depositTimelockProxy;

    EscrowTimelock internal escrowTimelockImpl;
    EscrowTimelock internal escrowTimelock;
    TransparentUpgradeableProxy internal escrowTimelockProxy;

    CollateralTimelock internal collateralTimelockImpl;
    CollateralTimelock internal collateralTimelock;
    TransparentUpgradeableProxy internal collateralTimelockProxy;

    TestERC721 internal testNFT;

    /**
     * @notice Opaque target address used in place of the LoanRouter while V2 tests are pending.
     *         Surviving timelock tests only need a stable address to key deposits against.
     */
    address internal loanRouter;

    /*------------------------------------------------------------------------*/
    /* Setup */
    /*------------------------------------------------------------------------*/

    function setUp() public virtual {
        // Fork Arbitrum mainnet
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"));
        vm.rollFork(401947600);

        // Create users
        users = Users({
            deployer: createUser("deployer"),
            admin: createUser("admin"),
            feeRecipient: createUser("feeRecipient"),
            borrower: createUser("borrower"),
            lender1: createUser("lender1"),
            lender2: createUser("lender2"),
            lender3: createUser("lender3"),
            liquidator: createUser("liquidator")
        });

        // Opaque loan-router target for timelock-only tests
        loanRouter = makeAddr("loanRouter");

        // Deploy Test NFT
        deployTestNFT();

        // Deploy supporting contracts
        deployDepositTimelock();
        deployEscrowTimelock();
        deployCollateralTimelock();

        // Fund users and wire approvals
        fundUsers();
        setApprovals();
    }

    /*------------------------------------------------------------------------*/
    /* Deployment functions */
    /*------------------------------------------------------------------------*/

    function deployDepositTimelock() internal {
        vm.startPrank(users.deployer);

        // Deploy implementation
        depositTimelockImpl = new DepositTimelock();

        // Deploy proxy
        depositTimelockProxy = new TransparentUpgradeableProxy(
            address(depositTimelockImpl),
            address(users.admin),
            abi.encodeWithSignature("initialize(address)", users.deployer)
        );
        depositTimelock = DepositTimelock(address(depositTimelockProxy));

        // Grant ERC20 depositor role to lenders
        AccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), users.lender1);
        AccessControl(address(depositTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), users.lender2);

        vm.stopPrank();
    }

    function deployEscrowTimelock() internal {
        vm.startPrank(users.deployer);

        // Deploy proxy
        escrowTimelockImpl = new EscrowTimelock(USDAI, STAKED_USDAI, users.admin);
        escrowTimelockProxy = new TransparentUpgradeableProxy(
            address(escrowTimelockImpl),
            address(users.admin),
            abi.encodeWithSignature("initialize(address)", users.deployer)
        );
        escrowTimelock = EscrowTimelock(address(escrowTimelockProxy));

        vm.stopPrank();
    }

    function deployCollateralTimelock() internal {
        vm.startPrank(users.deployer);

        // Deploy implementation
        collateralTimelockImpl = new CollateralTimelock();

        // Deploy proxy
        collateralTimelockProxy = new TransparentUpgradeableProxy(
            address(collateralTimelockImpl),
            address(users.admin),
            abi.encodeWithSignature("initialize(address)", users.deployer)
        );

        // Create interface
        collateralTimelock = CollateralTimelock(address(collateralTimelockProxy));

        // Grant ERC721 depositor role to depositors
        AccessControl(address(collateralTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), users.borrower);
        AccessControl(address(collateralTimelock)).grantRole(keccak256("DEPOSITOR_ROLE"), users.lender1);

        vm.stopPrank();
    }

    function deployTestNFT() internal {
        vm.startPrank(users.deployer);
        testNFT = new TestERC721("TestNFT", "TNFT");
        vm.stopPrank();
    }

    /*------------------------------------------------------------------------*/
    /* Setup helpers */
    /*------------------------------------------------------------------------*/

    function fundUsers() internal {
        deal(USDC, users.borrower, 1_000_000 * 1e6);
        deal(USDC, users.lender1, 10_000_000 * 1e6);
        deal(USDC, users.lender2, 10_000_000 * 1e6);
        deal(USDC, users.lender3, 10_000_000 * 1e6);

        deal(USDAI, users.lender1, 10_000_000 * 1e18);
        deal(USDAI, users.lender2, 10_000_000 * 1e18);
        deal(USDAI, users.lender3, 10_000_000 * 1e18);

        deal(USDT, users.lender1, 10_000_000 * 1e6);
        deal(USDT, users.lender2, 10_000_000 * 1e6);
        deal(USDT, users.lender3, 10_000_000 * 1e6);

        // Fund sUSDai and escrow admin for EscrowTimelock tests
        deal(USDAI, STAKED_USDAI, 10_000_000 * 1e18);
        deal(USDAI, users.admin, 100_000_000 * 1e18);
    }

    function setApprovals() internal {
        // Lender approvals into the DepositTimelock for each supported currency
        address payable[3] memory lenders = [users.lender1, users.lender2, users.lender3];
        for (uint256 i = 0; i < lenders.length; i++) {
            vm.startPrank(lenders[i]);
            IERC20(USDC).approve(address(depositTimelock), type(uint256).max);
            IERC20(USDAI).approve(address(depositTimelock), type(uint256).max);
            IERC20(USDT).approve(address(depositTimelock), type(uint256).max);
            vm.stopPrank();
        }

        // sUSDai approves EscrowTimelock to spend its USDai (for deposits)
        vm.prank(STAKED_USDAI);
        IERC20(USDAI).approve(address(escrowTimelock), type(uint256).max);

        // Escrow admin approves EscrowTimelock to spend its USDai (for cancel/withdraw interest)
        vm.prank(users.admin);
        IERC20(USDAI).approve(address(escrowTimelock), type(uint256).max);

        // Mock sUSDai to accept ERC721 receipt tokens (forked contract may not implement IERC721Receiver)
        vm.mockCall(
            STAKED_USDAI,
            abi.encodeWithSelector(IERC721Receiver.onERC721Received.selector),
            abi.encode(IERC721Receiver.onERC721Received.selector)
        );
    }

    /*------------------------------------------------------------------------*/
    /* Helpers */
    /*------------------------------------------------------------------------*/

    function createUser(
        string memory name
    ) internal returns (address payable addr) {
        addr = payable(makeAddr(name));
        vm.label({account: addr, newLabel: name});
        vm.deal({account: addr, newBalance: 100 ether});
    }

    function warp(
        uint256 timeInSeconds
    ) internal {
        vm.warp(block.timestamp + timeInSeconds);
    }

    function calculateExpectedInterest(
        uint256 principal,
        uint256 rate,
        uint256 duration
    ) internal pure returns (uint256) {
        return (principal * rate * duration) / FIXED_POINT_SCALE;
    }
}
