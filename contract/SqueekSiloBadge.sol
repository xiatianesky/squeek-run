// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Squeek Silo Badge — a game badge for SQUEEK SILO (fan game, not official).
//
// Deploy from Remix: paste this file, compiler 0.8.24+, target Sepolia
// (chain id 11155111). Constructor takes the signer address — the address
// whose key the leaderboard Worker holds. Minting needs a signature from it,
// so a badge can only be minted for a run the server has actually replayed.
//
// Everything the token is, lives on chain: traits are stored, and tokenURI
// builds the SVG by hand. No IPFS, no external host, no royalty on a game
// that costs nothing.

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC721/ERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/Strings.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/Base64.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";

contract SqueekSiloBadge is ERC721, Ownable {
    using Strings for uint256;
    using Strings for uint32;

    struct Run {
        uint32 round;
        uint32 score;
        uint16 blocks;
        uint8 tier;
        uint8 fur;
        uint8 accessory;
    }

    // Hard cap. Once 999 are gone the game keeps playing, the badge does not.
    uint256 public constant MAX_SUPPLY = 999;

    address public signer;
    bool public requireSignature = true;
    uint16 public maxPerAddress = 5;
    uint256 public totalMinted;

    mapping(address => uint16) public mintedBy;

    mapping(uint256 => Run) public runs;
    mapping(address => mapping(uint32 => bool)) public mintedRound;

    // 0xa418a2 is not used; the game id lives off chain in the page tag.
    string public constant GAME = "SQUEEK SILO";

    string[9] private FUR = [
        "#f5b81d", "#ff7828", "#ff82b4", "#50dca0", "#55aaff",
        "#b48cff", "#f0f0eb", "#aa6e3c", "#9696a0"
    ];
    string[9] private FUR_DARK = [
        "#b8891a", "#b3571b", "#b35a7e", "#38996f", "#3b76b3",
        "#7e61b3", "#b0b0a8", "#774d2a", "#6a6a74"
    ];

    event BadgeMinted(address indexed player, uint256 indexed tokenId, uint32 round, uint32 score, uint16 blocks);

    constructor(address signer_) ERC721("Squeek Silo Badge", "SILO") Ownable(msg.sender) {
        signer = signer_;
    }

    // ---- admin ------------------------------------------------------------
    function setSigner(address s) external onlyOwner { signer = s; }
    function setRequireSignature(bool v) external onlyOwner { requireSignature = v; }
    function setMaxPerAddress(uint16 v) external onlyOwner { maxPerAddress = v; }

    function remaining() external view returns (uint256) { return MAX_SUPPLY - totalMinted; }

    // ---- mint -------------------------------------------------------------
    function digestFor(address player, uint32 round, uint32 score, uint16 blocks)
        public view returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), player, round, score, blocks));
    }

    function mint(uint32 round, uint32 score, uint16 blocks, bytes calldata sig) external returns (uint256) {
        require(round > 0, "no round");
        require(totalMinted < MAX_SUPPLY, "sold out");
        require(mintedBy[msg.sender] < maxPerAddress, "address limit");
        require(!mintedRound[msg.sender][round], "one badge per run");

        if (requireSignature) {
            bytes32 h = MessageHashUtils.toEthSignedMessageHash(digestFor(msg.sender, round, score, blocks));
            require(ECDSA.recover(h, sig) == signer, "bad signature");
        }

        uint256 id = ++totalMinted;
        uint8 tier = uint8(_tierFor(score));
        runs[id] = Run({
            round: round,
            score: score,
            blocks: blocks,
            tier: tier,
            fur: uint8(round % 9),
            accessory: uint8((score / 25000) % 6)
        });
        mintedRound[msg.sender][round] = true;
        mintedBy[msg.sender] += 1;
        _safeMint(msg.sender, id);

        emit BadgeMinted(msg.sender, id, round, score, blocks);
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
            '","description":"A badge earned in SQUEEK SILO, a merge game for Squeekchain. Level, fur and accessory come from the run: two same-level Squeeks merge into one a level higher, and two level-6 Squeeks commit a block. Fan game, not official, not affiliated with Squeekchain.","attributes":[',
            '{"trait_type":"Tier","value":', uint256(r.tier).toString(), '},',
            '{"trait_type":"Round","value":', uint256(r.round).toString(), '},',
            '{"trait_type":"Score","value":', uint256(r.score).toString(), '},',
            '{"trait_type":"Blocks","value":', uint256(r.blocks).toString(), '}',
            '],"image":"data:image/svg+xml;base64,', Base64.encode(bytes(_svg(id, r))), '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _svg(uint256 id, Run memory r) private view returns (string memory) {
        string memory fur = FUR[r.fur];
        string memory furDark = FUR_DARK[r.fur];
        string memory acc = _accessory(r.accessory, r.tier);
        return string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 400'>",
            "<rect width='400' height='400' fill='#05081c'/>",
            "<rect x='12' y='12' width='376' height='376' fill='none' stroke='#ffd23f' stroke-width='6'/>",
            _squeek(fur, furDark, 100, 92, 200, 180),
            acc,
            "<text x='200' y='316' text-anchor='middle' font-family='Courier New,monospace' font-size='21' fill='#dbe4ff'>LEVEL ",
            uint256(r.tier).toString(),
            "</text>",
            "<text x='200' y='346' text-anchor='middle' font-family='Courier New,monospace' font-size='17' fill='#ffd23f'>",
            uint256(r.score).toString(),
            " POINTS</text>",
            _edition(id),
            "<text x='200' y='362' text-anchor='middle' font-family='Courier New,monospace' font-size='13' fill='#8fa3d9'>ROUND ",
            uint256(r.round).toString(),
            " / BLOCK ",
            uint256(r.blocks).toString(),
            "</text>",
            "</svg>"
        );
    }

    function _edition(uint256 id) private pure returns (string memory) {
        return string.concat(
            "<text x='200' y='386' text-anchor='middle' font-family='Courier New,monospace' font-size='15' fill='#8fa3d9'>",
            id.toString(), " / 999</text>"
        );
    }

    function _squeek(string memory fur, string memory furDark, uint256 x, uint256 y, uint256 w, uint256 h)
        private pure returns (string memory)
    {
        return string.concat(_ears(furDark, x, y, w, h), _face(fur, x, y, w, h), _whiskers(x, y, w, h));
    }

    function _ears(string memory furDark, uint256 x, uint256 y, uint256 w, uint256 h)
        private pure returns (string memory)
    {
        return string.concat(
            "<circle cx='", (x + w / 5).toString(), "' cy='", (y + h / 12).toString(), "' r='36' fill='", furDark, "'/>",
            "<circle cx='", (x + w - w / 5).toString(), "' cy='", (y + h / 12).toString(), "' r='36' fill='", furDark, "'/>",
            "<circle cx='", (x + w / 5).toString(), "' cy='", (y + h / 12).toString(), "' r='17' fill='#ffb3c7'/>",
            "<circle cx='", (x + w - w / 5).toString(), "' cy='", (y + h / 12).toString(), "' r='17' fill='#ffb3c7'/>"
        );
    }

    function _face(string memory fur, uint256 x, uint256 y, uint256 w, uint256 h)
        private pure returns (string memory)
    {
        string memory ey = (y + h * 42 / 100).toString();
        string memory cheeks = string.concat(
            "<circle cx='", (x + w * 28 / 100).toString(), "' cy='", (y + h * 72 / 100).toString(), "' r='19' fill='#ff7896' opacity='0.45'/>",
            "<circle cx='", (x + w * 72 / 100).toString(), "' cy='", (y + h * 72 / 100).toString(), "' r='19' fill='#ff7896' opacity='0.45'/>"
        );
        string memory eyes = string.concat(
            "<circle cx='", (x + w / 3).toString(), "' cy='", ey, "' r='14' fill='#0b0f24'/>",
            "<circle cx='", (x + w - w / 3).toString(), "' cy='", ey, "' r='14' fill='#0b0f24'/>"
        );
        string memory glints = string.concat(
            "<circle cx='", (x + w / 3 + 5).toString(), "' cy='", (y + h * 42 / 100 - 5).toString(), "' r='4' fill='#ffffff'/>",
            "<circle cx='", (x + w - w / 3 + 5).toString(), "' cy='", (y + h * 42 / 100 - 5).toString(), "' r='4' fill='#ffffff'/>"
        );
        return string.concat(
            "<rect x='", x.toString(), "' y='", y.toString(), "' width='", w.toString(), "' height='", h.toString(),
            "' rx='62' fill='", fur, "'/>", cheeks, eyes, glints
        );
    }

    function _whiskers(uint256 x, uint256 y, uint256 w, uint256 h) private pure returns (string memory) {
        string memory strip = "' stroke='#0b0f24' stroke-width='2' opacity='0.35' fill='none'/>";
        string memory nose =
            string.concat("<circle cx='", (x + w / 2).toString(), "' cy='", (y + h * 66 / 100).toString(), "' r='8' fill='#3a2140'/>");
        string memory wh1 = string.concat(
            "<path d='M", (x + w * 10 / 100).toString(), " ", (y + h * 62 / 100).toString(),
            " L", (x + w * 30 / 100).toString(), " ", (y + h * 65 / 100).toString(), strip
        );
        string memory wh2 = string.concat(
            "<path d='M", (x + w * 10 / 100).toString(), " ", (y + h * 76 / 100).toString(),
            " L", (x + w * 30 / 100).toString(), " ", (y + h * 73 / 100).toString(), strip
        );
        string memory wh3 = string.concat(
            "<path d='M", (x + w * 90 / 100).toString(), " ", (y + h * 62 / 100).toString(),
            " L", (x + w * 70 / 100).toString(), " ", (y + h * 65 / 100).toString(), strip
        );
        string memory wh4 = string.concat(
            "<path d='M", (x + w * 90 / 100).toString(), " ", (y + h * 76 / 100).toString(),
            " L", (x + w * 70 / 100).toString(), " ", (y + h * 73 / 100).toString(), strip
        );
        return string.concat(nose, wh1, wh2, wh3, wh4);
    }

    function _accessory(uint8 a, uint8 tier) private pure returns (string memory) {
        if (tier >= 6) {
            return "<polygon points='160,96 176,58 192,86 200,52 208,86 224,58 240,96' fill='#ffe98a'/>";
        }
        if (a == 4) {
            return "<rect x='150' y='166' width='44' height='28' rx='6' fill='#0b0f24'/><rect x='206' y='166' width='44' height='28' rx='6' fill='#0b0f24'/><rect x='194' y='174' width='12' height='8' fill='#0b0f24'/>";
        }
        if (a == 2) {
            return "<rect x='118' y='258' width='164' height='14' fill='#3b82ff'/>";
        }
        if (a == 1) {
            return "<circle cx='146' cy='212' r='11' fill='#ff7896' opacity='0.55'/><circle cx='254' cy='212' r='11' fill='#ff7896' opacity='0.55'/>";
        }
        return "";
    }
}

