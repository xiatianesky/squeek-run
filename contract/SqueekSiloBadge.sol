// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Squeek Silo Badge — a game badge for SQUEEK SILO, built on Squeekchain.
//
// This is the integration the Squeekchain docs sanction: read the deployed
// contracts, never try to write into them.
//
//   SqueekCore.state()         -> the round to gate on, and the completed
//                                 Squeek block height stamped in the token
//   SqueekCore.configuration() -> genesisTimestamp + roundDuration, so the
//                                 current round is derived the documented
//                                 way: floor((t - genesis) / duration) + 1
//   SqueekNFT.ownerOf/level    -> if the player names one of their Squeeks,
//                                 the badge carries that Squeek's real level
//
// Both reads are non-fatal: if the core ever moves or fails, minting still
// works, it just loses the stamp. Nothing here writes to Squeekchain.
//
// The signer address is the one whose key the leaderboard Worker holds, so a
// badge can only be minted for a run the server has actually replayed.
//
// Everything the token is lives on chain: traits are stored, and tokenURI
// builds the SVG by hand from the official 22x14 Squeek bitmap.

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC721/ERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/Strings.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/Base64.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";

interface ISqueekCore {
    function state() external view returns (
        uint64 settledThroughRound,
        uint64 cumulativeWork,
        uint96 cumulativeBlockUnits,
        uint64 blockHeight,
        uint96 blockProgress,
        uint32 workPerThousandBlocks,
        uint256 authorizationNonce,
        bool paused
    );

    function configuration() external view returns (
        bytes32 streamId,
        uint64 genesisTimestamp,
        uint64 roundDuration,
        uint64 maxWorkPerRound,
        uint16 maxRoundsPerBatch,
        address guardian,
        address reporter,
        uint32 initialWorkPerThousandBlocks,
        uint64 targetBlocksPerActiveRound,
        uint64 difficultySmoothingRounds,
        uint96 blockUnitsPerBlock
    );
}

interface ISqueekNFT {
    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function level(uint256 tokenId) external view returns (uint8);
}

contract SqueekSiloBadge is ERC721, Ownable {
    using Strings for uint256;

    struct Run {
        uint32 round;
        uint32 score;
        uint16 blocks;
        uint16 squeekId;
        uint8 tier;
        uint8 fur;
        uint8 squeekLevel;
        bool holder;
        uint64 coreBlock;
    }

    uint256 public constant MAX_SUPPLY = 999;

    // The Sepolia deployment, from docs.squeekchain.com/developers#deployments.
    // Read the proxies, never the implementations.
    address public constant CORE = 0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4;
    address public constant SQUEEK_NFT = 0xC4C7982657f00509548F3a3a41db7FA439a6856B;

    address public signer;
    bool public requireSignature = true;
    uint16 public maxPerAddress = 5;
    uint256 public totalMinted;

    mapping(address => uint16) public mintedBy;
    mapping(uint256 => Run) public runs;
    mapping(address => mapping(uint32 => bool)) public mintedRound;

    string public constant GAME = "SQUEEK SILO";

    string[9] private FUR = [
        "#f5b81d", "#ff7828", "#ff82b4", "#50dca0", "#55aaff",
        "#b48cff", "#f0f0eb", "#aa6e3c", "#9696a0"
    ];
    string[9] private FUR_DARK = [
        "#b8891a", "#b3571b", "#b35a7e", "#38996f", "#3b76b3",
        "#7e61b3", "#b0b0a8", "#774d2a", "#6a6a74"
    ];

    // The official Squeek face, 22 wide by 14 tall. 'o' is ink, '.' is air,
    // so the two slits between the centre strip and the cheeks read as eyes.
    string private constant R0  = "....ooo.......ooo.....";
    string private constant R1  = "...ooooo.....ooooo....";
    string private constant R2  = "...ooooooooooooooo....";
    string private constant R3  = "..ooooooooooooooooo...";
    string private constant R4  = "..oooo.ooooooo.oooo...";
    string private constant R5  = "..ooo...ooooo...ooo...";
    string private constant R6  = "..ooo...ooooo...ooo...";
    string private constant R7  = ".oooo...ooooo...oooo..";
    string private constant R8  = "ooooo...ooooo...ooooo.";
    string private constant R9  = "ooooo...ooooo...ooooo.";
    string private constant R10 = "oooooo.ooooooo.oooooo.";
    string private constant R11 = ".ooooooooooooooooooo..";
    string private constant R12 = "...ooooooooooooooo....";
    string private constant R13 = ".....ooooooooooo......";

    event BadgeMinted(
        address indexed player,
        uint256 indexed tokenId,
        uint32 round,
        uint32 score,
        uint16 blocks,
        uint64 coreBlock,
        uint16 squeekId,
        uint8 squeekLevel
    );

    constructor(address signer_) ERC721("Squeek Silo Badge", "SILO") Ownable(msg.sender) {
        signer = signer_;
    }

    // ---- admin ------------------------------------------------------------
    function setSigner(address s) external onlyOwner { signer = s; }
    function setRequireSignature(bool v) external onlyOwner { requireSignature = v; }
    function setMaxPerAddress(uint16 v) external onlyOwner { maxPerAddress = v; }

    function remaining() external view returns (uint256) { return MAX_SUPPLY - totalMinted; }

    // ---- official chain ---------------------------------------------------
    // One staticcall, decoded against the published ABI. state() is a static
    // tuple, so the eight fields arrive inline: word 0 is settledThroughRound
    // and word 3 is blockHeight.
    function chainState()
        public
        view
        returns (bool live, uint64 settledThroughRound, uint64 currentRound, uint64 blockHeight)
    {
        (bool ok, bytes memory data) = CORE.staticcall(abi.encodeWithSelector(ISqueekCore.state.selector));
        if (!ok || data.length < 256) return (false, 0, 0, 0);
        assembly ("memory-safe") {
            settledThroughRound := mload(add(data, 0x20))
            blockHeight := mload(add(data, 0x80))
        }
        currentRound = 0;
        (bool okCfg, bytes memory cfg) = CORE.staticcall(abi.encodeWithSelector(ISqueekCore.configuration.selector));
        if (okCfg && cfg.length >= 352) {
            uint64 genesis;
            uint64 duration;
            assembly ("memory-safe") {
                genesis := mload(add(cfg, 0x40))
                duration := mload(add(cfg, 0x60))
            }
            if (duration > 0 && block.timestamp >= genesis) {
                currentRound = uint64((block.timestamp - genesis) / duration) + 1;
            }
        }
    }

    // Does the player hold an official Squeek? The docs list this holder check
    // as a supported way to build on the collection; it costs one staticcall.
    function holdsSqueek(address player) public view returns (bool) {
        (bool ok, bytes memory data) =
            SQUEEK_NFT.staticcall(abi.encodeWithSelector(ISqueekNFT.balanceOf.selector, player));
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (uint256)) > 0;
    }

    // Level of a Squeek the player actually owns, 1-based. Returns 0 when the
    // token is not theirs, so callers can treat 0 as "no Squeek named".
    function squeekLevelOf(uint256 tokenId, address player) public view returns (uint8) {
        (bool okOwner, bytes memory ownerData) =
            SQUEEK_NFT.staticcall(abi.encodeWithSelector(ISqueekNFT.ownerOf.selector, tokenId));
        if (!okOwner || ownerData.length < 32) return 0;
        if (abi.decode(ownerData, (address)) != player) return 0;
        (bool okLv, bytes memory lv) =
            SQUEEK_NFT.staticcall(abi.encodeWithSelector(ISqueekNFT.level.selector, tokenId));
        if (!okLv || lv.length < 32) return 0;
        return uint8(abi.decode(lv, (uint256))) + 1; // 0 = never merged, i.e. Level 1
    }

    // ---- mint -------------------------------------------------------------
    // The digest binds the run to this contract, this chain and this player, so
    // a signature cannot be replayed elsewhere. squeekId is part of it because
    // it decides a trait; 0 means "no Squeek named".
    function digestFor(address player, uint32 round, uint32 score, uint16 blocks, uint32 squeekId)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), player, round, score, blocks, squeekId));
    }

    function mint(uint32 round, uint32 score, uint16 blocks, uint32 squeekId, bytes calldata sig)
        external
        returns (uint256)
    {
        require(round > 0, "no round");
        require(score > 0, "no score");
        require(totalMinted < MAX_SUPPLY, "sold out");
        require(mintedBy[msg.sender] < maxPerAddress, "address limit");
        require(!mintedRound[msg.sender][round], "one badge per run");
        require(squeekId == 0 || squeekId <= 9999, "bad squeek id");

        (bool live, uint64 settled, uint64 currentRound, uint64 coreBlock) = chainState();
        if (live) {
            // A badge may describe the round that just closed or the one running
            // now; never one the chain has not reached.
            uint64 ceiling = currentRound > 0 ? currentRound : settled + 1;
            require(round <= ceiling, "round not on chain yet");
        }

        uint8 lv = 0;
        if (squeekId > 0) {
            lv = squeekLevelOf(squeekId, msg.sender);
            require(lv > 0, "not your squeek");
        }
        bool holder = lv > 0 || holdsSqueek(msg.sender);

        if (requireSignature) {
            bytes32 h =
                MessageHashUtils.toEthSignedMessageHash(digestFor(msg.sender, round, score, blocks, squeekId));
            require(ECDSA.recover(h, sig) == signer, "bad signature");
        }

        uint256 id = ++totalMinted;
        Run storage run_ = runs[id];
        run_.round = round;
        run_.score = score;
        run_.blocks = blocks;
        run_.squeekId = uint16(squeekId);
        run_.tier = uint8(_tierFor(score));
        run_.fur = uint8(round % 9);
        run_.squeekLevel = lv;
        run_.holder = holder;
        run_.coreBlock = live ? coreBlock : 0;
        mintedRound[msg.sender][round] = true;
        mintedBy[msg.sender] += 1;
        _safeMint(msg.sender, id);

        emit BadgeMinted(msg.sender, id, round, score, blocks, runs[id].coreBlock, run_.squeekId, lv);
        return id;
    }

    function _tierFor(uint32 score) private pure returns (uint256) {
        if (score >= 400000) return 6;
        if (score >= 200000) return 5;
        if (score >= 100000) return 4;
        if (score >= 50000) return 3;
        if (score >= 15000) return 2;
        return 1;
    }

    // ---- metadata ---------------------------------------------------------
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        Run memory r = runs[id];

        string memory json = string.concat(
            '{"name":"Squeek Silo Badge #', id.toString(),
            '","description":"A badge earned in SQUEEK SILO, a merge game on Squeekchain. Two same-level Squeeks merge into one a level higher, and two level-6 Squeeks commit a block. Stamped with the official chain state at mint time.","attributes":[',
            '{"trait_type":"Tier","value":', uint256(r.tier).toString(), '},',
            '{"trait_type":"Round","value":', uint256(r.round).toString(), '},',
            '{"trait_type":"Score","value":', uint256(r.score).toString(), '},',
            '{"trait_type":"Blocks","value":', uint256(r.blocks).toString(), '},',
            '{"trait_type":"SqueekHolder","value":', r.holder ? "true" : "false", '},',
            '{"trait_type":"Squeek","value":', uint256(r.squeekId).toString(), '},',
            '{"trait_type":"SqueekLevel","value":', uint256(r.squeekLevel).toString(), '},',
            '{"trait_type":"ChainBlock","value":', uint256(r.coreBlock).toString(), '}',
            '],"image":"data:image/svg+xml;base64,', Base64.encode(bytes(_svg(id, r))), '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _svg(uint256 id, Run memory r) private view returns (string memory) {
        return string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 400'>",
            "<rect width='400' height='400' fill='#05081c'/>",
            "<rect x='12' y='12' width='376' height='376' fill='none' stroke='#ffd23f' stroke-width='6'/>",
            _pixelFace(FUR[r.fur], FUR_DARK[r.fur]),
            "<text x='200' y='300' text-anchor='middle' font-family='Courier New,monospace' font-size='21' fill='#dbe4ff'>LEVEL ",
            uint256(r.tier).toString(),
            "</text>",
            "<text x='200' y='331' text-anchor='middle' font-family='Courier New,monospace' font-size='17' fill='#ffd23f'>",
            uint256(r.score).toString(),
            " POINTS</text>",
            _holderLine(r),
            _footer(id, r),
            "</svg>"
        );
    }

    // A badge can carry the Squeek it was minted with. That is the collection's
    // own record, not ours: level 0 there means never merged, i.e. Level 1.
    function _holderLine(Run memory r) private pure returns (string memory) {
        if (r.squeekId > 0) {
            return string.concat(
                "<text x='200' y='284' text-anchor='middle' font-family='Courier New,monospace' font-size='13' fill='#50dca0'>SQUEEK #",
                uint256(r.squeekId).toString(),
                " / LV ",
                uint256(r.squeekLevel).toString(),
                "</text>"
            );
        }
        if (r.holder) {
            return "<text x='200' y='284' text-anchor='middle' font-family='Courier New,monospace' font-size='13' fill='#50dca0'>SQUEEK HOLDER</text>";
        }
        return "";
    }

    function _footer(uint256 id, Run memory r) private pure returns (string memory) {
        string memory line = r.coreBlock == 0
            ? string.concat("ROUND ", uint256(r.round).toString(), " / BLOCKS ", uint256(r.blocks).toString())
            : string.concat("ROUND ", uint256(r.round).toString(), " / CHAIN BLOCK ", uint256(r.coreBlock).toString());
        return string.concat(
            "<text x='200' y='356' text-anchor='middle' font-family='Courier New,monospace' font-size='13' fill='#8fa3d9'>",
            line,
            "</text>",
            "<text x='200' y='375' text-anchor='middle' font-family='Courier New,monospace' font-size='14' fill='#8fa3d9'>",
            id.toString(), " / 999</text>"
        );
    }

    // Grid units 22x14 scaled to 320x204 and placed under the border.
    function _pixelFace(string memory fur, string memory furDark) private pure returns (string memory) {
        string[14] memory g = [R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, R10, R11, R12, R13];
        bytes memory d = "";
        for (uint256 row = 0; row < 14; row++) {
            bytes memory cells = bytes(g[row]);
            for (uint256 col = 0; col < 22; col++) {
                if (cells[col] == 0x6f) {
                    d = abi.encodePacked(d, "M", col.toString(), " ", row.toString(), "h.8v.8h-.8z");
                }
            }
        }
        return string.concat(
            "<g transform='translate(50 64) scale(13.6)'><path d='", string(d),
            "' fill='", fur, "' stroke='", furDark, "' stroke-width='0.05'/></g>"
        );
    }
}
