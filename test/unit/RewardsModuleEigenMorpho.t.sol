// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {TezoroV1_2} from "../../src/TezoroV1_2.sol";
import {RewardsModuleV1_2} from "../../src/RewardsModuleV1_2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockUSDCToken, MockRewardToken, MockStrategy, MockDexRouter, MerkleHelper} from "./shared/RewardsModuleTestBase.sol";

// ========================================================================
// Pattern 4: EigenLayer-Style Two-Level Merkle Distributor
//
// Architecture:
//   Level 1 (Earner Tree): leaf = hash(earner, earnerTokenRoot)
//   Level 2 (Token Tree):  leaf = hash(token, cumulativeAmount)
//
// The claim struct contains proofs at both levels. This is fundamentally
// different from flat merkle distributors (Merkl, URD, OZ).
//
// Ref: github.com/Layr-Labs/eigenlayer-contracts RewardsCoordinator
// ========================================================================

contract EigenLayerStyleDistributor {
    using SafeERC20 for IERC20;

    struct TokenLeaf {
        address token;
        uint256 cumulativeAmount;
    }

    struct EarnerLeaf {
        address earner;
        bytes32 earnerTokenRoot;
    }

    struct RewardsClaim {
        bytes32[] earnerProof;
        EarnerLeaf earnerLeaf;
        uint32[] tokenIndices;
        bytes32[][] tokenProofs;
        TokenLeaf[] tokenLeaves;
    }

    bytes32 public distributionRoot;
    mapping(address => mapping(address => uint256)) public cumulativeClaimed;

    function setDistributionRoot(bytes32 root) external {
        distributionRoot = root;
    }

    /// @notice Process a two-level merkle claim.
    function processClaim(RewardsClaim calldata claim, address recipient) external {
        // Level 1: Verify earner leaf against distribution root
        bytes32 earnerHash = keccak256(abi.encodePacked(claim.earnerLeaf.earner, claim.earnerLeaf.earnerTokenRoot));
        require(MerkleProof.verify(claim.earnerProof, distributionRoot, earnerHash), "Invalid earner proof");

        // Level 2: Verify each token leaf against earner's token root
        for (uint256 i = 0; i < claim.tokenLeaves.length; i++) {
            TokenLeaf calldata tl = claim.tokenLeaves[i];
            bytes32 tokenHash = keccak256(abi.encodePacked(tl.token, tl.cumulativeAmount));
            require(
                MerkleProof.verify(claim.tokenProofs[i], claim.earnerLeaf.earnerTokenRoot, tokenHash),
                "Invalid token proof"
            );

            uint256 alreadyClaimed = cumulativeClaimed[claim.earnerLeaf.earner][tl.token];
            uint256 toClaim = tl.cumulativeAmount - alreadyClaimed;

            if (toClaim > 0) {
                cumulativeClaimed[claim.earnerLeaf.earner][tl.token] = tl.cumulativeAmount;
                IERC20(tl.token).safeTransfer(recipient, toClaim);
            }
        }
    }
}

// ========================================================================
// Pattern 5: Realistic Morpho URD (double-keccak256 leaf hashing)
//
// Real Morpho URD uses: keccak256(bytes.concat(keccak256(abi.encode(account, reward, claimable))))
// This is a defense against second preimage attacks.
//
// Ref: github.com/morpho-org/universal-rewards-distributor
// ========================================================================

contract RealisticMorphoUrd {
    using SafeERC20 for IERC20;

    bytes32 public root;
    address public owner;
    mapping(address => mapping(address => uint256)) public claimed;

    constructor(address owner_) {
        owner = owner_;
    }

    function setRoot(bytes32 root_) external {
        require(msg.sender == owner, "not owner");
        root = root_;
    }

    /// @notice Claim using double-keccak256 leaf hashing (matches real URD)
    function claim(address account, address reward, uint256 claimable, bytes32[] calldata proof)
        external
        returns (uint256 amount)
    {
        // Double hash: keccak256(bytes.concat(keccak256(abi.encode(...))))
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, reward, claimable))));
        require(MerkleProof.verify(proof, root, leaf), "invalid proof");

        uint256 alreadyClaimed = claimed[account][reward];
        amount = claimable - alreadyClaimed;
        require(amount > 0, "nothing to claim");

        claimed[account][reward] = claimable;
        IERC20(reward).safeTransfer(account, amount);
    }
}

// ========================================================================
// Tests
// ========================================================================

contract RewardsModuleEigenMorphoTest is Test {

    MockUSDCToken usdc;
    MockRewardToken morpho;
    MockRewardToken eigen;
    TezoroV1_2 vault;
    RewardsModuleV1_2 module;
    MockStrategy strategy;
    MockDexRouter router;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");

    uint256 constant DEPOSIT = 100_000e6;

    function setUp() public {
        usdc = new MockUSDCToken();
        morpho = new MockRewardToken("Morpho", "MORPHO");
        eigen = new MockRewardToken("EigenLayer", "EIGEN");
        router = new MockDexRouter(address(usdc));

        vault = new TezoroV1_2(
            IERC20(address(usdc)), "Tezoro USDC-A", "tUSDC-A",
            admin, makeAddr("feeRecipient"), 1_500, 300
        );

        module = new RewardsModuleV1_2(address(vault), admin);
        strategy = new MockStrategy(address(usdc));

        vm.startPrank(admin);
        vault.addStrategy(IStrategy(address(strategy)));
        vault.setKeeper(keeper);
        vault.setRewardsModule(address(module));
        module.setKeeper(keeper);
        module.setRouterWhitelist(address(router), true);
        vm.stopPrank();

        usdc.mint(alice, DEPOSIT * 10);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
    }

    // =========================================================================
    // Pattern 4: EigenLayer Two-Level Merkle
    // =========================================================================

    function test_pattern4_eigenLayer_singleTokenClaim() public {
        uint256 eigenAmount = 2_000e18;

        // Build token tree (level 2): single token leaf
        bytes32 tokenLeafHash = keccak256(abi.encodePacked(address(eigen), eigenAmount));
        bytes32 tokenLeafDummy = keccak256(abi.encodePacked(address(0xdead), uint256(0)));
        bytes32 tokenRoot = MerkleHelper.rootOf2(tokenLeafHash, tokenLeafDummy);

        // Build earner tree (level 1): module is the earner
        bytes32 earnerHash = keccak256(abi.encodePacked(address(module), tokenRoot));
        bytes32 earnerDummy = keccak256(abi.encodePacked(makeAddr("otherEarner"), bytes32(0)));
        bytes32 distRoot = MerkleHelper.rootOf2(earnerHash, earnerDummy);

        // Deploy and configure
        EigenLayerStyleDistributor distributor = new EigenLayerStyleDistributor();
        distributor.setDistributionRoot(distRoot);
        eigen.mint(address(distributor), 5_000e18);

        vm.prank(admin);
        module.setClaimWhitelist(address(distributor), EigenLayerStyleDistributor.processClaim.selector, true);

        // Build claim struct
        EigenLayerStyleDistributor.TokenLeaf[] memory tokenLeaves = new EigenLayerStyleDistributor.TokenLeaf[](1);
        tokenLeaves[0] = EigenLayerStyleDistributor.TokenLeaf(address(eigen), eigenAmount);

        uint32[] memory tokenIndices = new uint32[](1);
        tokenIndices[0] = 0;

        bytes32[][] memory tokenProofs = new bytes32[][](1);
        tokenProofs[0] = MerkleHelper.proofFor0(tokenLeafHash, tokenLeafDummy);

        EigenLayerStyleDistributor.RewardsClaim memory claim = EigenLayerStyleDistributor.RewardsClaim({
            earnerProof: MerkleHelper.proofFor0(earnerHash, earnerDummy),
            earnerLeaf: EigenLayerStyleDistributor.EarnerLeaf(address(module), tokenRoot),
            tokenIndices: tokenIndices,
            tokenProofs: tokenProofs,
            tokenLeaves: tokenLeaves
        });

        bytes memory claimData = abi.encodeCall(
            EigenLayerStyleDistributor.processClaim, (claim, address(module))
        );

        vm.prank(keeper);
        module.executeClaim(address(distributor), claimData);

        assertEq(eigen.balanceOf(address(module)), eigenAmount, "EIGEN claimed via EigenLayer-style");
    }

    function test_pattern4_eigenLayer_multiTokenClaim() public {
        uint256 eigenAmount = 1_000e18;
        uint256 morphoAmount = 500e18;

        // Build token tree (level 2): two token leaves
        bytes32 eigenLeaf = keccak256(abi.encodePacked(address(eigen), eigenAmount));
        bytes32 morphoLeaf = keccak256(abi.encodePacked(address(morpho), morphoAmount));
        bytes32 tokenRoot = MerkleHelper.rootOf2(eigenLeaf, morphoLeaf);

        // Build earner tree (level 1)
        bytes32 earnerHash = keccak256(abi.encodePacked(address(module), tokenRoot));
        bytes32 earnerDummy = keccak256(abi.encodePacked(makeAddr("other"), bytes32(0)));
        bytes32 distRoot = MerkleHelper.rootOf2(earnerHash, earnerDummy);

        EigenLayerStyleDistributor distributor = new EigenLayerStyleDistributor();
        distributor.setDistributionRoot(distRoot);
        eigen.mint(address(distributor), 5_000e18);
        morpho.mint(address(distributor), 5_000e18);

        vm.prank(admin);
        module.setClaimWhitelist(address(distributor), EigenLayerStyleDistributor.processClaim.selector, true);

        // Claim both tokens in one call
        EigenLayerStyleDistributor.TokenLeaf[] memory tokenLeaves = new EigenLayerStyleDistributor.TokenLeaf[](2);
        tokenLeaves[0] = EigenLayerStyleDistributor.TokenLeaf(address(eigen), eigenAmount);
        tokenLeaves[1] = EigenLayerStyleDistributor.TokenLeaf(address(morpho), morphoAmount);

        uint32[] memory tokenIndices = new uint32[](2);
        bytes32[][] memory tokenProofs = new bytes32[][](2);
        tokenProofs[0] = MerkleHelper.proofFor0(eigenLeaf, morphoLeaf);
        tokenProofs[1] = MerkleHelper.proofFor1(eigenLeaf, morphoLeaf);

        EigenLayerStyleDistributor.RewardsClaim memory claim = EigenLayerStyleDistributor.RewardsClaim({
            earnerProof: MerkleHelper.proofFor0(earnerHash, earnerDummy),
            earnerLeaf: EigenLayerStyleDistributor.EarnerLeaf(address(module), tokenRoot),
            tokenIndices: tokenIndices,
            tokenProofs: tokenProofs,
            tokenLeaves: tokenLeaves
        });

        vm.prank(keeper);
        module.executeClaim(
            address(distributor),
            abi.encodeCall(EigenLayerStyleDistributor.processClaim, (claim, address(module)))
        );

        assertEq(eigen.balanceOf(address(module)), eigenAmount, "EIGEN claimed");
        assertEq(morpho.balanceOf(address(module)), morphoAmount, "MORPHO claimed");
    }

    function test_pattern4_eigenLayer_invalidEarnerProof_reverts() public {
        bytes32 tokenRoot = keccak256("tokenRoot");
        bytes32 earnerHash = keccak256(abi.encodePacked(address(module), tokenRoot));
        bytes32 earnerDummy = keccak256(abi.encodePacked(makeAddr("x"), bytes32(0)));
        bytes32 distRoot = MerkleHelper.rootOf2(earnerHash, earnerDummy);

        EigenLayerStyleDistributor distributor = new EigenLayerStyleDistributor();
        distributor.setDistributionRoot(distRoot);

        vm.prank(admin);
        module.setClaimWhitelist(address(distributor), EigenLayerStyleDistributor.processClaim.selector, true);

        // Wrong proof (use proof for index 1 instead of 0)
        EigenLayerStyleDistributor.RewardsClaim memory claim = EigenLayerStyleDistributor.RewardsClaim({
            earnerProof: MerkleHelper.proofFor1(earnerHash, earnerDummy), // WRONG
            earnerLeaf: EigenLayerStyleDistributor.EarnerLeaf(address(module), tokenRoot),
            tokenIndices: new uint32[](0),
            tokenProofs: new bytes32[][](0),
            tokenLeaves: new EigenLayerStyleDistributor.TokenLeaf[](0)
        });

        vm.prank(keeper);
        vm.expectRevert(RewardsModuleV1_2.ClaimFailed.selector);
        module.executeClaim(
            address(distributor),
            abi.encodeCall(EigenLayerStyleDistributor.processClaim, (claim, address(module)))
        );
    }

    function test_pattern4_eigenLayer_e2e_claimSwapSweep() public {
        uint256 eigenAmount = 3_000e18;

        // Build two-level tree
        bytes32 tokenLeaf = keccak256(abi.encodePacked(address(eigen), eigenAmount));
        bytes32 tokenDummy = keccak256(abi.encodePacked(address(0xdead), uint256(0)));

        bytes32 earnerHash = keccak256(abi.encodePacked(address(module), MerkleHelper.rootOf2(tokenLeaf, tokenDummy)));
        bytes32 earnerDummy = keccak256(abi.encodePacked(makeAddr("x"), bytes32(0)));

        EigenLayerStyleDistributor distributor = new EigenLayerStyleDistributor();
        distributor.setDistributionRoot(MerkleHelper.rootOf2(earnerHash, earnerDummy));
        eigen.mint(address(distributor), 5_000e18);

        vm.prank(admin);
        module.setClaimWhitelist(address(distributor), EigenLayerStyleDistributor.processClaim.selector, true);

        uint256 totalBefore = vault.totalAssets();

        // Step 1: Claim
        _eigenClaim(distributor, address(eigen), eigenAmount, tokenLeaf, tokenDummy, earnerHash, earnerDummy);
        assertEq(eigen.balanceOf(address(module)), eigenAmount, "Claimed");

        // Step 2+3: Swap and sweep
        _swapAndSweep(address(eigen), eigenAmount, 1_500e6);

        assertEq(vault.totalAssets(), totalBefore + 1_500e6, "Vault increased");
    }

    /// @dev Helper: swap reward token to USDC and sweep to vault
    function _swapAndSweep(address tokenIn, uint256 amountIn, uint256 usdcAmount) internal {
        usdc.mint(address(router), usdcAmount);
        router.setUsdcOut(usdcAmount);
        vm.prank(keeper);
        module.swap(
            address(router), tokenIn, address(usdc), amountIn, usdcAmount,
            abi.encodeCall(MockDexRouter.doSwap, (tokenIn, amountIn))
        );
        vm.prank(keeper);
        module.sweepToVault();
    }

    function _eigenClaim(
        EigenLayerStyleDistributor distributor,
        address token,
        uint256 amount,
        bytes32 tokenLeaf,
        bytes32 tokenDummy,
        bytes32 earnerHash,
        bytes32 earnerDummy
    ) internal {
        bytes32 tokenRoot = MerkleHelper.rootOf2(tokenLeaf, tokenDummy);

        EigenLayerStyleDistributor.TokenLeaf[] memory tl = new EigenLayerStyleDistributor.TokenLeaf[](1);
        tl[0] = EigenLayerStyleDistributor.TokenLeaf(token, amount);

        bytes32[][] memory tp = new bytes32[][](1);
        tp[0] = MerkleHelper.proofFor0(tokenLeaf, tokenDummy);

        EigenLayerStyleDistributor.RewardsClaim memory claim = EigenLayerStyleDistributor.RewardsClaim({
            earnerProof: MerkleHelper.proofFor0(earnerHash, earnerDummy),
            earnerLeaf: EigenLayerStyleDistributor.EarnerLeaf(address(module), tokenRoot),
            tokenIndices: new uint32[](1),
            tokenProofs: tp,
            tokenLeaves: tl
        });

        vm.prank(keeper);
        module.executeClaim(
            address(distributor),
            abi.encodeCall(EigenLayerStyleDistributor.processClaim, (claim, address(module)))
        );
    }

    // =========================================================================
    // Pattern 5: Realistic Morpho URD (double-keccak256)
    // =========================================================================

    function test_pattern5_realisticMorphoUrd_claim() public {
        uint256 claimable = 1_000e18;

        // Double-hash leaf (matches real Morpho URD)
        bytes32 leaf0 = keccak256(bytes.concat(keccak256(abi.encode(address(module), address(morpho), claimable))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(makeAddr("x"), address(morpho), uint256(200e18)))));

        bytes32 root = MerkleHelper.rootOf2(leaf0, leaf1);
        bytes32[] memory proof = MerkleHelper.proofFor0(leaf0, leaf1);

        RealisticMorphoUrd urd = new RealisticMorphoUrd(admin);
        vm.prank(admin);
        urd.setRoot(root);
        morpho.mint(address(urd), 2_000e18);

        vm.prank(admin);
        module.setClaimWhitelist(address(urd), RealisticMorphoUrd.claim.selector, true);

        vm.prank(keeper);
        module.executeClaim(
            address(urd),
            abi.encodeCall(RealisticMorphoUrd.claim, (address(module), address(morpho), claimable, proof))
        );

        assertEq(morpho.balanceOf(address(module)), claimable, "MORPHO claimed via realistic URD");
    }

    function test_pattern5_realisticMorphoUrd_cumulativeClaim() public {
        uint256 first = 500e18;
        uint256 second = 1_500e18;

        // First round
        bytes32 leaf0 = keccak256(bytes.concat(keccak256(abi.encode(address(module), address(morpho), first))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(makeAddr("x"), address(morpho), uint256(100e18)))));

        RealisticMorphoUrd urd = new RealisticMorphoUrd(admin);
        vm.prank(admin);
        urd.setRoot(MerkleHelper.rootOf2(leaf0, leaf1));
        morpho.mint(address(urd), 5_000e18);

        vm.prank(admin);
        module.setClaimWhitelist(address(urd), RealisticMorphoUrd.claim.selector, true);

        vm.prank(keeper);
        module.executeClaim(
            address(urd),
            abi.encodeCall(RealisticMorphoUrd.claim, (address(module), address(morpho), first, MerkleHelper.proofFor0(leaf0, leaf1)))
        );
        assertEq(morpho.balanceOf(address(module)), first, "First claim");

        // Second round (new root, higher cumulative)
        bytes32 leaf0b = keccak256(bytes.concat(keccak256(abi.encode(address(module), address(morpho), second))));
        bytes32 leaf1b = keccak256(bytes.concat(keccak256(abi.encode(makeAddr("x"), address(morpho), uint256(100e18)))));

        vm.prank(admin);
        urd.setRoot(MerkleHelper.rootOf2(leaf0b, leaf1b));

        vm.prank(keeper);
        module.executeClaim(
            address(urd),
            abi.encodeCall(RealisticMorphoUrd.claim, (address(module), address(morpho), second, MerkleHelper.proofFor0(leaf0b, leaf1b)))
        );

        assertEq(morpho.balanceOf(address(module)), second, "Cumulative claim");
    }

    function test_pattern5_realisticMorphoUrd_e2e() public {
        uint256 claimable = 2_000e18;

        bytes32 leaf0 = keccak256(bytes.concat(keccak256(abi.encode(address(module), address(morpho), claimable))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(makeAddr("x"), address(morpho), uint256(100e18)))));

        RealisticMorphoUrd urd = new RealisticMorphoUrd(admin);
        vm.prank(admin);
        urd.setRoot(MerkleHelper.rootOf2(leaf0, leaf1));
        morpho.mint(address(urd), 5_000e18);

        vm.prank(admin);
        module.setClaimWhitelist(address(urd), RealisticMorphoUrd.claim.selector, true);

        uint256 totalBefore = vault.totalAssets();

        // Claim
        vm.prank(keeper);
        module.executeClaim(
            address(urd),
            abi.encodeCall(RealisticMorphoUrd.claim, (address(module), address(morpho), claimable, MerkleHelper.proofFor0(leaf0, leaf1)))
        );

        // Swap + Sweep
        _swapAndSweep(address(morpho), claimable, 1_000e6);

        assertEq(vault.totalAssets(), totalBefore + 1_000e6, "Vault increased");
    }
}
