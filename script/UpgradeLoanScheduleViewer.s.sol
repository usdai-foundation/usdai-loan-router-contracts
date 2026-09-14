// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {LoanScheduleViewer} from "src/LoanScheduleViewer.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract UpgradeLoanScheduleViewer is Deployer {
    function run() public broadcast useDeployment returns (address) {
        if (_deployment.loanRouterV2 == address(0x0)) revert MissingDependency();
        if (_deployment.loanScheduleViewer == address(0x0)) revert MissingDependency();

        // Deploy LoanScheduleViewer implementation
        LoanScheduleViewer viewerImpl = new LoanScheduleViewer(_deployment.loanRouterV2);
        console.log("LoanScheduleViewer implementation", address(viewerImpl));

        /* Lookup proxy admin */
        address proxyAdmin = address(uint160(uint256(vm.load(_deployment.loanScheduleViewer, ERC1967Utils.ADMIN_SLOT))));

        if (Ownable(proxyAdmin).owner() == msg.sender) {
            /* Upgrade Proxy */
            ProxyAdmin(proxyAdmin)
                .upgradeAndCall(ITransparentUpgradeableProxy(_deployment.loanScheduleViewer), address(viewerImpl), "");
            console.log(
                "Upgraded proxy %s implementation to: %s\n", _deployment.loanScheduleViewer, address(viewerImpl)
            );
        } else {
            console.log("\nUpgrade calldata");
            console.log("Target:   %s", proxyAdmin);
            console.log("Calldata:");
            console.logBytes(
                abi.encodeWithSelector(
                    ProxyAdmin.upgradeAndCall.selector,
                    ITransparentUpgradeableProxy(_deployment.loanScheduleViewer),
                    address(viewerImpl),
                    ""
                )
            );
        }

        return address(viewerImpl);
    }
}
