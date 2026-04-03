// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {TezoroV1_1} from "../../src/TezoroV1_1.sol";
import {RewardsModule} from "../../src/RewardsModule.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockUSDCToken, MockRewardToken, MockStrategy, MockDexRouter, MerkleHelper} from "./shared/RewardsModuleTestBase.sol";

// ========================================================================
// Pattern 1: Simple Merkle Distributor
// (OpenZeppelin-style: one token, index-based, single claim per leaf)
// Used by: simple airdrops, governance token distributions
// ========================================================================

contract SimpleMerkleDistributor {
    using SafeERC20 for IERC20;

    address public token;
    bytes32 public merkleRoot;
    mapping(uint256 => bool) public claimed;

    constructor(address token_, bytes32 merkleRoot_) {
        token = token_;
        merkleRoot = merkleRoot_;
    }

    /// @notice Claim airdrop. Leaf = keccak256(abi.encodePacked(index, account, amount))
    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external {
        require(!claimed[index], "Already claimed");

        bytes32 leaf = keccak256(abi.encodePacked(index, account, amount));
        require(MerkleProof.verify(proof, merkleRoot, leaf), "Invalid proof");

        claimed[index] = true;
        IERC20(token).safeTransfer(account, amount);
    }
}

// ========================================================================
// Pattern 2: Merkl-Style Batch Distributor
// (Angle/Merkl: multi-user, multi-token, cumulative amounts)
// Used by: Merkl (0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae)
// ========================================================================

contract MerklStyleDistributor {
    using SafeERC20 for IERC20;

    /// @dev Per-user, per-token merkle root
    mapping(address => bytes32) public merkleRoots; // token => root
    /// @dev Cumulative claimed amounts
    mapping(address => mapping(address => uint256)) public claimed; // user => token => cumulative

    function setMerkleRoot(address token, bytes32 root) external {
        merkleRoots[token] = root;
    }

    /// @notice Batch claim. Leaf = keccak256(abi.encodePacked(user, token, cumulativeAmount))
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external {
        require(users.length == tokens.length, "Length mismatch");
        require(users.length == amounts.length, "Length mismatch");
        require(users.length == proofs.length, "Length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            bytes32 leaf = keccak256(abi.encodePacked(users[i], tokens[i], amounts[i]));
            require(MerkleProof.verify(proofs[i], merkleRoots[tokens[i]], leaf), "Invalid proof");

            uint256 alreadyClaimed = claimed[users[i]][tokens[i]];
            uint256 toClaim = amounts[i] - alreadyClaimed;

            if (toClaim > 0) {
                claimed[users[i]][tokens[i]] = amounts[i];
                IERC20(tokens[i]).safeTransfer(users[i], toClaim);
            }
        }
    }
}

// ========================================================================
// Pattern 3: Morpho URD-Style Distributor
// (Per-token root, cumulative, single claim per call)
// Used by: Morpho Universal Reward Distributor
// ========================================================================

contract MorphoUrdDistributor {
    using SafeERC20 for IERC20;

    /// @dev token => merkle root
    mapping(address => bytes32) public roots;
    /// @dev account => token => already claimed cumulative
    mapping(address => mapping(address => uint256)) public claimed;

    function setRoot(address token, bytes32 root) external {
        roots[token] = root;
    }

    /// @notice Claim rewards. Leaf = keccak256(abi.encodePacked(account, reward, claimable))
    function claim(address account, address reward, uint256 claimable, bytes32[] calldata proof) external {
        bytes32 leaf = keccak256(abi.encodePacked(account, reward, claimable));
        require(MerkleProof.verify(proof, roots[reward], leaf), "Invalid proof");

        uint256 alreadyClaimed = claimed[account][reward];
        require(claimable > alreadyClaimed, "Nothing to claim");

        uint256 toClaim = claimable - alreadyClaimed;
        claimed[account][reward] = claimable;
        IERC20(reward).safeTransfer(account, toClaim);
    }
}

// ========================================================================
// Tests
// ========================================================================

contract RewardsModuleMerkleTest is Test {

    MockUSDCToken usdc;
    MockRewardToken morpho;
    MockRewardToken arb;
    TezoroV1_1 vault;
    RewardsModule module;
    MockStrategy strategy;
    MockDexRouter router;

    address admin = makeAddr("admin");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");

    uint256 constant DEPOSIT = 100_000e6;

    function setUp() public {
        usdc = new MockUSDCToken();
        morpho = new MockRewardToken("Morpho", "MORPHO");
        arb = new MockRewardToken("Arbitrum", "ARB");
        router = new MockDexRouter(address(usdc));

        vault = new TezoroV1_1(
            IERC20(address(usdc)),
            "Tezoro USDC-A",
            "tUSDC-A",
            admin,
            makeAddr("feeRecipient"),
            1_500,
            300
        );

        module = new RewardsModule(address(vault), admin);
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
    // Pattern 1: Simple Merkle Distributor (OZ-style airdrop)
    // =========================================================================

    function test_pattern1_simpleMerkle_claim() public {
        uint256 rewardAmount = 1_000e18;

        // Build merkle tree: 2 leaves
        bytes32 leaf0 = keccak256(abi.encodePacked(uint256(0), address(module), rewardAmount));
        bytes32 leaf1 = keccak256(abi.encodePacked(uint256(1), makeAddr("user2"), uint256(500e18)));

        (bytes32 root, bytes32[] memory proof) = _buildTreeAndProof(leaf0, leaf1);

        // Deploy distributor and fund it
        SimpleMerkleDistributor distributor = new SimpleMerkleDistributor(address(morpho), root);
        morpho.mint(address(distributor), 2_000e18);

        // Whitelist the claim selector
        bytes4 selector = SimpleMerkleDistributor.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(distributor), selector, true);

        // Execute claim via RewardsModule
        bytes memory claimData = abi.encodeCall(
            SimpleMerkleDistributor.claim,
            (0, address(module), rewardAmount, proof)
        );

        uint256 before = morpho.balanceOf(address(module));

        vm.prank(keeper);
        module.executeClaim(address(distributor), claimData);

        assertEq(morpho.balanceOf(address(module)) - before, rewardAmount, "MORPHO should arrive at module");
    }

    function test_pattern1_simpleMerkle_invalidProof_reverts() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(uint256(0), address(module), uint256(1_000e18)));
        leaves[1] = keccak256(abi.encodePacked(uint256(1), makeAddr("user2"), uint256(500e18)));

        bytes32 root = MerkleHelper.rootOf2(leaves[0], leaves[1]);
        bytes32[] memory wrongProof = MerkleHelper.proofFor1(leaves[0], leaves[1]); // proof for wrong leaf

        SimpleMerkleDistributor distributor = new SimpleMerkleDistributor(address(morpho), root);
        morpho.mint(address(distributor), 2_000e18);

        bytes4 selector = SimpleMerkleDistributor.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(distributor), selector, true);

        // Use wrong proof — distributor reverts, RM wraps as ClaimFailed
        bytes memory claimData = abi.encodeCall(
            SimpleMerkleDistributor.claim,
            (0, address(module), 1_000e18, wrongProof)
        );

        vm.prank(keeper);
        vm.expectRevert(RewardsModule.ClaimFailed.selector);
        module.executeClaim(address(distributor), claimData);
    }

    function test_pattern1_simpleMerkle_doubleClaim_reverts() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(uint256(0), address(module), uint256(1_000e18)));
        leaves[1] = keccak256(abi.encodePacked(uint256(1), makeAddr("user2"), uint256(500e18)));

        bytes32 root = MerkleHelper.rootOf2(leaves[0], leaves[1]);
        bytes32[] memory proof = MerkleHelper.proofFor0(leaves[0], leaves[1]);

        SimpleMerkleDistributor distributor = new SimpleMerkleDistributor(address(morpho), root);
        morpho.mint(address(distributor), 2_000e18);

        bytes4 selector = SimpleMerkleDistributor.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(distributor), selector, true);

        bytes memory claimData = abi.encodeCall(
            SimpleMerkleDistributor.claim,
            (0, address(module), 1_000e18, proof)
        );

        // First claim succeeds
        vm.prank(keeper);
        module.executeClaim(address(distributor), claimData);

        // Second claim fails (already claimed)
        vm.prank(keeper);
        vm.expectRevert(RewardsModule.ClaimFailed.selector);
        module.executeClaim(address(distributor), claimData);
    }

    // =========================================================================
    // Pattern 2: Merkl-Style Batch Distributor (multi-user, multi-token)
    // =========================================================================

    function test_pattern2_merklBatch_singleClaim() public {
        uint256 morphoAmount = 500e18;

        // Build tree for MORPHO token
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(address(strategy), address(morpho), morphoAmount));
        leaves[1] = keccak256(abi.encodePacked(makeAddr("other"), address(morpho), uint256(200e18)));

        bytes32 root = MerkleHelper.rootOf2(leaves[0], leaves[1]);
        bytes32[] memory proof = MerkleHelper.proofFor0(leaves[0], leaves[1]);

        MerklStyleDistributor distributor = new MerklStyleDistributor();
        distributor.setMerkleRoot(address(morpho), root);
        morpho.mint(address(distributor), 1_000e18);

        // Whitelist Merkl claim selector
        bytes4 selector = MerklStyleDistributor.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(distributor), selector, true);

        // Build batch arrays (single entry)
        address[] memory users = new address[](1);
        users[0] = address(strategy);
        address[] memory tokens = new address[](1);
        tokens[0] = address(morpho);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = morphoAmount;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = proof;

        bytes memory claimData = abi.encodeCall(MerklStyleDistributor.claim, (users, tokens, amounts, proofs));

        // Claim — tokens land on strategy (not module)
        vm.prank(keeper);
        module.executeClaim(address(distributor), claimData);

        assertEq(morpho.balanceOf(address(strategy)), morphoAmount, "MORPHO should arrive at strategy");

        // Sweep from strategy to module
        vm.prank(keeper);
        vault.sweepStrategyReward(IStrategy(address(strategy)), address(morpho));

        assertEq(morpho.balanceOf(address(module)), morphoAmount, "MORPHO should be in module after sweep");
        assertEq(morpho.balanceOf(address(strategy)), 0, "Strategy should be empty");
    }

    /// @dev Helper: build 2-leaf tree and return root + proof for leaf 0
    function _buildTreeAndProof(bytes32 leaf0, bytes32 leaf1) internal pure returns (bytes32 root, bytes32[] memory proof) {
        root = MerkleHelper.rootOf2(leaf0, leaf1);
        proof = MerkleHelper.proofFor0(leaf0, leaf1);
    }

    function test_pattern2_merklBatch_multiToken() public {
        uint256 morphoAmount = 500e18;
        uint256 arbAmount = 1_000e18;

        (bytes32 morphoRoot, bytes32[] memory morphoProof) = _buildTreeAndProof(
            keccak256(abi.encodePacked(address(strategy), address(morpho), morphoAmount)),
            keccak256(abi.encodePacked(makeAddr("x"), address(morpho), uint256(100e18)))
        );

        (bytes32 arbRoot, bytes32[] memory arbProof) = _buildTreeAndProof(
            keccak256(abi.encodePacked(address(strategy), address(arb), arbAmount)),
            keccak256(abi.encodePacked(makeAddr("y"), address(arb), uint256(300e18)))
        );

        MerklStyleDistributor distributor = new MerklStyleDistributor();
        distributor.setMerkleRoot(address(morpho), morphoRoot);
        distributor.setMerkleRoot(address(arb), arbRoot);
        morpho.mint(address(distributor), 1_000e18);
        arb.mint(address(distributor), 2_000e18);

        vm.prank(admin);
        module.setClaimWhitelist(address(distributor), MerklStyleDistributor.claim.selector, true);

        // Batch claim
        bytes memory claimData = _encodeBatchClaim(
            address(strategy), address(strategy),
            address(morpho), address(arb),
            morphoAmount, arbAmount,
            morphoProof, arbProof
        );

        vm.prank(keeper);
        module.executeClaim(address(distributor), claimData);

        assertEq(morpho.balanceOf(address(strategy)), morphoAmount, "MORPHO on strategy");
        assertEq(arb.balanceOf(address(strategy)), arbAmount, "ARB on strategy");

        // Sweep both tokens
        vm.prank(keeper);
        vault.sweepStrategyReward(IStrategy(address(strategy)), address(morpho));
        vm.prank(keeper);
        vault.sweepStrategyReward(IStrategy(address(strategy)), address(arb));

        assertEq(morpho.balanceOf(address(module)), morphoAmount, "MORPHO in module");
        assertEq(arb.balanceOf(address(module)), arbAmount, "ARB in module");
    }

    /// @dev Helper: encode Merkl batch claim with 2 entries
    function _encodeBatchClaim(
        address user0, address user1,
        address token0, address token1,
        uint256 amount0, uint256 amount1,
        bytes32[] memory proof0, bytes32[] memory proof1
    ) internal pure returns (bytes memory) {
        address[] memory users = new address[](2);
        users[0] = user0;
        users[1] = user1;
        address[] memory tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = proof0;
        proofs[1] = proof1;
        return abi.encodeCall(MerklStyleDistributor.claim, (users, tokens, amounts, proofs));
    }

    function test_pattern2_merklBatch_cumulativeClaim() public {
        uint256 firstAmount = 300e18;
        uint256 secondAmount = 800e18; // cumulative, not incremental

        // First distribution
        bytes32[] memory leaves1 = new bytes32[](2);
        leaves1[0] = keccak256(abi.encodePacked(address(module), address(morpho), firstAmount));
        leaves1[1] = keccak256(abi.encodePacked(makeAddr("x"), address(morpho), uint256(100e18)));
        bytes32 root1 = MerkleHelper.rootOf2(leaves1[0], leaves1[1]);
        bytes32[] memory proof1 = MerkleHelper.proofFor0(leaves1[0], leaves1[1]);

        MerklStyleDistributor distributor = new MerklStyleDistributor();
        distributor.setMerkleRoot(address(morpho), root1);
        morpho.mint(address(distributor), 2_000e18);

        bytes4 selector = MerklStyleDistributor.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(distributor), selector, true);

        // First claim: 300 MORPHO
        {
            address[] memory users = new address[](1);
            users[0] = address(module);
            address[] memory tokens = new address[](1);
            tokens[0] = address(morpho);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = firstAmount;
            bytes32[][] memory proofs = new bytes32[][](1);
            proofs[0] = proof1;

            vm.prank(keeper);
            module.executeClaim(address(distributor), abi.encodeCall(MerklStyleDistributor.claim, (users, tokens, amounts, proofs)));
        }
        assertEq(morpho.balanceOf(address(module)), firstAmount, "First claim: 300 MORPHO");

        // Second distribution (new root with higher cumulative amount)
        bytes32[] memory leaves2 = new bytes32[](2);
        leaves2[0] = keccak256(abi.encodePacked(address(module), address(morpho), secondAmount));
        leaves2[1] = keccak256(abi.encodePacked(makeAddr("x"), address(morpho), uint256(100e18)));
        bytes32 root2 = MerkleHelper.rootOf2(leaves2[0], leaves2[1]);
        bytes32[] memory proof2 = MerkleHelper.proofFor0(leaves2[0], leaves2[1]);

        distributor.setMerkleRoot(address(morpho), root2);

        // Second claim: cumulative 800 MORPHO → net 500 MORPHO (800 - 300 already claimed)
        {
            address[] memory users = new address[](1);
            users[0] = address(module);
            address[] memory tokens = new address[](1);
            tokens[0] = address(morpho);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = secondAmount;
            bytes32[][] memory proofs = new bytes32[][](1);
            proofs[0] = proof2;

            vm.prank(keeper);
            module.executeClaim(address(distributor), abi.encodeCall(MerklStyleDistributor.claim, (users, tokens, amounts, proofs)));
        }

        // Should have 300 + 500 = 800 total
        assertEq(morpho.balanceOf(address(module)), secondAmount, "Cumulative claim: 800 MORPHO total");
    }

    // =========================================================================
    // Pattern 3: Morpho URD-Style Distributor
    // =========================================================================

    function test_pattern3_morphoUrd_singleClaim() public {
        uint256 claimable = 1_000e18;

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(address(module), address(morpho), claimable));
        leaves[1] = keccak256(abi.encodePacked(makeAddr("user2"), address(morpho), uint256(500e18)));

        bytes32 root = MerkleHelper.rootOf2(leaves[0], leaves[1]);
        bytes32[] memory proof = MerkleHelper.proofFor0(leaves[0], leaves[1]);

        MorphoUrdDistributor urd = new MorphoUrdDistributor();
        urd.setRoot(address(morpho), root);
        morpho.mint(address(urd), 2_000e18);

        bytes4 selector = MorphoUrdDistributor.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(urd), selector, true);

        bytes memory claimData = abi.encodeCall(
            MorphoUrdDistributor.claim,
            (address(module), address(morpho), claimable, proof)
        );

        vm.prank(keeper);
        module.executeClaim(address(urd), claimData);

        assertEq(morpho.balanceOf(address(module)), claimable, "MORPHO claimed via URD");
    }

    function test_pattern3_morphoUrd_cumulativeClaim() public {
        uint256 first = 500e18;
        uint256 second = 1_200e18;

        // First round
        bytes32[] memory leaves1 = new bytes32[](2);
        leaves1[0] = keccak256(abi.encodePacked(address(module), address(morpho), first));
        leaves1[1] = keccak256(abi.encodePacked(makeAddr("z"), address(morpho), uint256(100e18)));
        bytes32 root1 = MerkleHelper.rootOf2(leaves1[0], leaves1[1]);
        bytes32[] memory proof1 = MerkleHelper.proofFor0(leaves1[0], leaves1[1]);

        MorphoUrdDistributor urd = new MorphoUrdDistributor();
        urd.setRoot(address(morpho), root1);
        morpho.mint(address(urd), 5_000e18);

        bytes4 selector = MorphoUrdDistributor.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(urd), selector, true);

        vm.prank(keeper);
        module.executeClaim(address(urd), abi.encodeCall(MorphoUrdDistributor.claim, (address(module), address(morpho), first, proof1)));
        assertEq(morpho.balanceOf(address(module)), first, "First URD claim");

        // Second round (new root, higher cumulative)
        bytes32[] memory leaves2 = new bytes32[](2);
        leaves2[0] = keccak256(abi.encodePacked(address(module), address(morpho), second));
        leaves2[1] = keccak256(abi.encodePacked(makeAddr("z"), address(morpho), uint256(100e18)));
        bytes32 root2 = MerkleHelper.rootOf2(leaves2[0], leaves2[1]);
        bytes32[] memory proof2 = MerkleHelper.proofFor0(leaves2[0], leaves2[1]);

        urd.setRoot(address(morpho), root2);

        vm.prank(keeper);
        module.executeClaim(address(urd), abi.encodeCall(MorphoUrdDistributor.claim, (address(module), address(morpho), second, proof2)));

        // 500 + (1200 - 500) = 1200
        assertEq(morpho.balanceOf(address(module)), second, "Cumulative URD claim");
    }

    function test_pattern3_morphoUrd_invalidProof_reverts() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(address(module), address(morpho), uint256(1_000e18)));
        leaves[1] = keccak256(abi.encodePacked(makeAddr("x"), address(morpho), uint256(500e18)));
        bytes32 root = MerkleHelper.rootOf2(leaves[0], leaves[1]);
        bytes32[] memory wrongProof = MerkleHelper.proofFor1(leaves[0], leaves[1]);

        MorphoUrdDistributor urd = new MorphoUrdDistributor();
        urd.setRoot(address(morpho), root);
        morpho.mint(address(urd), 2_000e18);

        bytes4 selector = MorphoUrdDistributor.claim.selector;
        vm.prank(admin);
        module.setClaimWhitelist(address(urd), selector, true);

        vm.prank(keeper);
        vm.expectRevert(RewardsModule.ClaimFailed.selector);
        module.executeClaim(address(urd), abi.encodeCall(MorphoUrdDistributor.claim, (address(module), address(morpho), 1_000e18, wrongProof)));
    }

    // =========================================================================
    // Full E2E: Merkle claim → sweep → swap → vault deposit
    // =========================================================================

    function test_e2e_simpleMerkle_claimSwapSweep() public {
        uint256 rewardAmount = 1_000e18;
        uint256 swapOutput = 500e6; // 500 USDC from selling MORPHO

        // Build tree and distributor
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(uint256(0), address(module), rewardAmount));
        leaves[1] = keccak256(abi.encodePacked(uint256(1), makeAddr("x"), uint256(100e18)));
        bytes32 root = MerkleHelper.rootOf2(leaves[0], leaves[1]);
        bytes32[] memory proof = MerkleHelper.proofFor0(leaves[0], leaves[1]);

        SimpleMerkleDistributor distributor = new SimpleMerkleDistributor(address(morpho), root);
        morpho.mint(address(distributor), 2_000e18);

        vm.startPrank(admin);
        module.setClaimWhitelist(address(distributor), SimpleMerkleDistributor.claim.selector, true);
        vm.stopPrank();

        uint256 totalBefore = vault.totalAssets();

        // Step 1: Claim via executeClaim
        vm.prank(keeper);
        module.executeClaim(
            address(distributor),
            abi.encodeCall(SimpleMerkleDistributor.claim, (0, address(module), rewardAmount, proof))
        );
        assertEq(morpho.balanceOf(address(module)), rewardAmount, "Step 1: MORPHO in module");

        // Step 2: Swap MORPHO → USDC
        usdc.mint(address(router), swapOutput);
        router.setUsdcOut(swapOutput);
        vm.prank(keeper);
        module.swap(
            address(router), address(morpho), address(usdc), rewardAmount, swapOutput,
            abi.encodeCall(MockDexRouter.doSwap, (address(morpho), rewardAmount))
        );
        assertEq(usdc.balanceOf(address(module)), swapOutput, "Step 2: USDC in module");

        // Step 3: Sweep to vault
        vm.prank(keeper);
        module.sweepToVault();

        assertEq(vault.totalAssets(), totalBefore + swapOutput, "Step 3: vault totalAssets increased");
        assertEq(usdc.balanceOf(address(module)), 0, "Module empty after sweep");
    }

    function test_e2e_merklBatch_multiTokenClaimSwapSweep() public {
        uint256 morphoAmount = 500e18;
        uint256 arbAmount = 1_000e18;

        (bytes32 morphoRoot, bytes32[] memory morphoProof) = _buildTreeAndProof(
            keccak256(abi.encodePacked(address(strategy), address(morpho), morphoAmount)),
            keccak256(abi.encodePacked(makeAddr("x"), address(morpho), uint256(100e18)))
        );
        (bytes32 arbRoot, bytes32[] memory arbProof) = _buildTreeAndProof(
            keccak256(abi.encodePacked(address(strategy), address(arb), arbAmount)),
            keccak256(abi.encodePacked(makeAddr("y"), address(arb), uint256(100e18)))
        );

        MerklStyleDistributor distributor = new MerklStyleDistributor();
        distributor.setMerkleRoot(address(morpho), morphoRoot);
        distributor.setMerkleRoot(address(arb), arbRoot);
        morpho.mint(address(distributor), 1_000e18);
        arb.mint(address(distributor), 2_000e18);

        vm.prank(admin);
        module.setClaimWhitelist(address(distributor), MerklStyleDistributor.claim.selector, true);

        uint256 totalBefore = vault.totalAssets();

        // Step 1: Batch claim (tokens land on strategy)
        vm.prank(keeper);
        module.executeClaim(address(distributor), _encodeBatchClaim(
            address(strategy), address(strategy),
            address(morpho), address(arb),
            morphoAmount, arbAmount,
            morphoProof, arbProof
        ));

        // Step 2: Sweep from strategy to module
        vm.prank(keeper);
        vault.sweepStrategyReward(IStrategy(address(strategy)), address(morpho));
        vm.prank(keeper);
        vault.sweepStrategyReward(IStrategy(address(strategy)), address(arb));

        // Step 3: Swap MORPHO → USDC
        _swapReward(address(morpho), morphoAmount, 250e6);

        // Step 4: Swap ARB → USDC
        _swapReward(address(arb), arbAmount, 800e6);

        // Step 5: Sweep to vault
        vm.prank(keeper);
        module.sweepToVault();

        assertEq(vault.totalAssets(), totalBefore + 1_050e6, "Vault got all rewards");
        assertEq(usdc.balanceOf(address(module)), 0, "Module empty");
    }

    /// @dev Helper: swap reward token to USDC via mock router
    function _swapReward(address tokenIn, uint256 amountIn, uint256 usdcAmount) internal {
        usdc.mint(address(router), usdcAmount);
        router.setUsdcOut(usdcAmount);
        vm.prank(keeper);
        module.swap(
            address(router), tokenIn, address(usdc), amountIn, usdcAmount,
            abi.encodeCall(MockDexRouter.doSwap, (tokenIn, amountIn))
        );
    }

    function test_e2e_morphoUrd_claimSwapSweep() public {
        uint256 claimable = 2_000e18;
        uint256 swapOutput = 1_000e6;

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(address(module), address(morpho), claimable));
        leaves[1] = keccak256(abi.encodePacked(makeAddr("x"), address(morpho), uint256(100e18)));
        bytes32 root = MerkleHelper.rootOf2(leaves[0], leaves[1]);
        bytes32[] memory proof = MerkleHelper.proofFor0(leaves[0], leaves[1]);

        MorphoUrdDistributor urd = new MorphoUrdDistributor();
        urd.setRoot(address(morpho), root);
        morpho.mint(address(urd), 5_000e18);

        vm.prank(admin);
        module.setClaimWhitelist(address(urd), MorphoUrdDistributor.claim.selector, true);

        uint256 totalBefore = vault.totalAssets();

        // Claim
        vm.prank(keeper);
        module.executeClaim(address(urd), abi.encodeCall(MorphoUrdDistributor.claim, (address(module), address(morpho), claimable, proof)));

        // Swap
        usdc.mint(address(router), swapOutput);
        router.setUsdcOut(swapOutput);
        vm.prank(keeper);
        module.swap(
            address(router), address(morpho), address(usdc), claimable, swapOutput,
            abi.encodeCall(MockDexRouter.doSwap, (address(morpho), claimable))
        );

        // Sweep
        vm.prank(keeper);
        module.sweepToVault();

        assertEq(vault.totalAssets(), totalBefore + swapOutput, "Vault totalAssets increased");
    }

    // =========================================================================
    // Cross-pattern: Multiple distributors, different patterns, same module
    // =========================================================================

    function test_e2e_multipleDistributors_sameModule() public {
        // Pattern 1: Simple airdrop → tokens to module directly
        bytes32[] memory simpleLeaves = new bytes32[](2);
        simpleLeaves[0] = keccak256(abi.encodePacked(uint256(0), address(module), uint256(300e18)));
        simpleLeaves[1] = keccak256(abi.encodePacked(uint256(1), makeAddr("x"), uint256(100e18)));

        SimpleMerkleDistributor simpleDistributor = new SimpleMerkleDistributor(address(arb), MerkleHelper.rootOf2(simpleLeaves[0], simpleLeaves[1]));
        arb.mint(address(simpleDistributor), 500e18);

        // Pattern 3: Morpho URD → tokens to module directly
        bytes32[] memory urdLeaves = new bytes32[](2);
        urdLeaves[0] = keccak256(abi.encodePacked(address(module), address(morpho), uint256(700e18)));
        urdLeaves[1] = keccak256(abi.encodePacked(makeAddr("y"), address(morpho), uint256(200e18)));

        MorphoUrdDistributor urd = new MorphoUrdDistributor();
        urd.setRoot(address(morpho), MerkleHelper.rootOf2(urdLeaves[0], urdLeaves[1]));
        morpho.mint(address(urd), 1_000e18);

        // Whitelist both distributors
        vm.startPrank(admin);
        module.setClaimWhitelist(address(simpleDistributor), SimpleMerkleDistributor.claim.selector, true);
        module.setClaimWhitelist(address(urd), MorphoUrdDistributor.claim.selector, true);
        vm.stopPrank();

        // Claim from both
        vm.prank(keeper);
        module.executeClaim(
            address(simpleDistributor),
            abi.encodeCall(SimpleMerkleDistributor.claim, (0, address(module), 300e18, MerkleHelper.proofFor0(simpleLeaves[0], simpleLeaves[1])))
        );

        vm.prank(keeper);
        module.executeClaim(
            address(urd),
            abi.encodeCall(MorphoUrdDistributor.claim, (address(module), address(morpho), 700e18, MerkleHelper.proofFor0(urdLeaves[0], urdLeaves[1])))
        );

        assertEq(arb.balanceOf(address(module)), 300e18, "ARB from simple distributor");
        assertEq(morpho.balanceOf(address(module)), 700e18, "MORPHO from URD");

        // Swap both and sweep
        uint256 totalBefore = vault.totalAssets();

        usdc.mint(address(router), 150e6);
        router.setUsdcOut(150e6);
        vm.prank(keeper);
        module.swap(address(router), address(arb), address(usdc), 300e18, 150e6, abi.encodeCall(MockDexRouter.doSwap, (address(arb), 300e18)));

        usdc.mint(address(router), 350e6);
        router.setUsdcOut(350e6);
        vm.prank(keeper);
        module.swap(address(router), address(morpho), address(usdc), 700e18, 350e6, abi.encodeCall(MockDexRouter.doSwap, (address(morpho), 700e18)));

        vm.prank(keeper);
        module.sweepToVault();

        assertEq(vault.totalAssets(), totalBefore + 500e6, "Vault received combined rewards");
    }
}
