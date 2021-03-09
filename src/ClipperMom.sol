// SPDX-License-Identifier: AGPL-3.0-or-later

/// ClipperMom.sol -- governance interface for the Clipper

// Copyright (C) 2021 Maker Ecosystem Growth Holdings, INC.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.6.12;

interface ClipLike {
    function file(bytes32, uint256) external;
}

interface AuthorityLike {
    function canCall(address src, address dst, bytes4 sig) external view returns (bool);
}

contract ClipperMom {
    address public owner;
    address public authority;
    
    event SetOwner(address indexed oldOwner, address indexed newOwner);
    event SetAuthority(address indexed oldAuthority, address indexed newAuthority);
    event SetBreaker(address indexed clip, uint256 level);

    modifier onlyOwner {
        require(msg.sender == owner, "clipper-mom/only-owner");
        _;
    }

    modifier auth {
        require(isAuthorized(msg.sender, msg.sig), "clipper-mom/not-authorized");
        _;
    }

    constructor() public {
        owner = msg.sender;
        emit SetOwner(address(0), msg.sender);
    }

    function isAuthorized(address src, bytes4 sig) internal view returns (bool) {
        if (src == address(this)) {
            return true;
        } else if (src == owner) {
            return true;
        } else if (authority == address(0)) {
            return false;
        } else {
            return AuthorityLike(authority).canCall(src, address(this), sig);
        }
    }

    function setOwner(address owner_) external onlyOwner {
        emit SetOwner(owner, owner_);
        owner = owner_;
    }

    function setAuthority(address authority_) external onlyOwner {
        emit SetAuthority(authority, authority_);
        authority = authority_;
    }

    function setBreaker(address clip, uint256 level) external auth {
        require(level <= 2, "ClipperMom/wrong-level");
        ClipLike(clip).file("stopped", level);
        emit SetBreaker(clip, level);
    }
}
