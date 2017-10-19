<#
.NOTES
    Author: Robert D. Biddle
    https://github.com/RobBiddle
    https://github.com/RobBiddle/PackerBaseAMI
    PackerBaseAMI  Copyright (C) 2017  Robert D. Biddle
    This program comes with ABSOLUTELY NO WARRANTY; for details type `"help New-PackerBaseAMI -full`".
    This is free software, and you are welcome to redistribute it
    under certain conditions; for details type `"help New-PackerBaseAMI -full`".
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
    The GNU General Public License does not permit incorporating your program
    into proprietary programs.  If your program is a subroutine library, you
    may consider it more useful to permit linking proprietary applications with
    the library.  If this is what you want to do, use the GNU Lesser General
    Public License instead of this License.  But first, please read
    <http://www.gnu.org/philosophy/why-not-lgpl.html>.
#>
Function Get-ShortDate {
    Param
    (
        [Parameter(Mandatory = $false)]
        [Switch]
        $FilenameCompatibleFormat
    )
    if ($FilenameCompatibleFormat) {
        $($Date = Get-Date; $Date.ToShortDateString()).Replace("/", "-")
    }
    Else {
        $Date = Get-Date; $Date.ToShortDateString()
    }
}
Function Get-ShortTime {
    Param
    (
        [Parameter(Mandatory = $false)]
        [Switch]
        $FilenameCompatibleFormat
    )
    if ($FilenameCompatibleFormat) {
        $($Time = get-date; $Time.ToShortTimeString()).Replace(":", "-").Replace(" ", "-")
    }
    Else {
        $Time = Get-Date; $Time.ToShortTimeString()
    }
}

