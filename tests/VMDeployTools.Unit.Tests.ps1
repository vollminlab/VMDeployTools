#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\VMDeployTools.psd1') -Force
}

# ===========================================================================
# Find-SiblingRepo
# ===========================================================================
Describe 'Find-SiblingRepo' -Tag 'Unit' {

    Context 'HTTPS remote URL' {
        It 'Parses owner and finds matching sibling repo' {
            InModuleScope VMDeployTools {
                Mock git {
                    # First call: this repo's own remote
                    # Subsequent calls: sibling dir remotes
                    if ($args -contains $PSScriptRoot) {
                        return 'https://github.com/testowner/VMDeployTools'
                    }
                    return 'https://github.com/testowner/homelab-infrastructure'
                }
                Mock Get-ChildItem {
                    return @([PSCustomObject]@{ FullName = 'C:\fake\homelab-infrastructure' })
                }

                $result = Find-SiblingRepo -RepoName 'homelab-infrastructure'
                $result | Should -Be 'C:\fake\homelab-infrastructure'
            }
        }
    }

    Context 'SSH remote URL' {
        It 'Parses owner from git@github.com SSH URL' {
            InModuleScope VMDeployTools {
                Mock git {
                    if ($args -contains $PSScriptRoot) {
                        return 'git@github.com:testowner/VMDeployTools'
                    }
                    return 'git@github.com:testowner/homelab-infrastructure'
                }
                Mock Get-ChildItem {
                    return @([PSCustomObject]@{ FullName = 'C:\fake\homelab-infrastructure' })
                }

                $result = Find-SiblingRepo -RepoName 'homelab-infrastructure'
                $result | Should -Be 'C:\fake\homelab-infrastructure'
            }
        }
    }

    Context 'No match' {
        It 'Returns $null when no sibling repo matches' {
            InModuleScope VMDeployTools {
                Mock git {
                    if ($args -contains $PSScriptRoot) {
                        return 'https://github.com/testowner/VMDeployTools'
                    }
                    return 'https://github.com/testowner/some-other-repo'
                }
                Mock Get-ChildItem {
                    return @([PSCustomObject]@{ FullName = 'C:\fake\some-other-repo' })
                }

                $result = Find-SiblingRepo -RepoName 'homelab-infrastructure'
                $result | Should -BeNullOrEmpty
            }
        }
    }

    Context 'RelativePath parameter' {
        It 'Appends RelativePath to the found repo root' {
            InModuleScope VMDeployTools {
                Mock git {
                    if ($args -contains $PSScriptRoot) {
                        return 'https://github.com/testowner/VMDeployTools'
                    }
                    return 'https://github.com/testowner/homelab-infrastructure'
                }
                Mock Get-ChildItem {
                    return @([PSCustomObject]@{ FullName = 'C:\fake\homelab-infrastructure' })
                }

                $result = Find-SiblingRepo -RepoName 'homelab-infrastructure' `
                                           -RelativePath 'hosts/windows/ssh/config'
                $result | Should -Be (Join-Path 'C:\fake\homelab-infrastructure' 'hosts/windows/ssh/config')
            }
        }
    }
}

# ===========================================================================
# Remove-HostBlockFromConfig
# ===========================================================================
Describe 'Remove-HostBlockFromConfig' -Tag 'Unit' {

    It 'Removes the target Host block, leaves other blocks intact' {
        InModuleScope VMDeployTools {
            $configFile = Join-Path $TestDrive 'config_remove_target'
            Set-Content $configFile -Value @(
                'Host web01'
                '  HostName web01.vollminlab.com'
                '  User vollmin'
                ''
                'Host db01'
                '  HostName db01.vollminlab.com'
                '  User vollmin'
            )

            Remove-HostBlockFromConfig -HostName 'web01' -ConfigPath $configFile

            $result = Get-Content $configFile -Raw
            $result | Should -Not -Match 'web01\.vollminlab\.com'
            $result | Should -Match 'db01'
        }
    }

    It 'Does not remove other Host blocks when removing from middle' {
        InModuleScope VMDeployTools {
            $configFile = Join-Path $TestDrive 'config_remove_middle'
            Set-Content $configFile -Value @(
                'Host alpha'
                '  HostName alpha.example.com'
                ''
                'Host beta'
                '  HostName beta.example.com'
                ''
                'Host gamma'
                '  HostName gamma.example.com'
            )

            Remove-HostBlockFromConfig -HostName 'beta' -ConfigPath $configFile

            $result = Get-Content $configFile -Raw
            $result | Should -Match 'alpha'
            $result | Should -Not -Match 'beta\.example\.com'
            $result | Should -Match 'gamma'
        }
    }

    It 'Skips cleanly when file does not exist' {
        InModuleScope VMDeployTools {
            $nonexistent = Join-Path $TestDrive 'no_such_file'
            { Remove-HostBlockFromConfig -HostName 'web01' -ConfigPath $nonexistent } |
                Should -Not -Throw
        }
    }

    It 'Skips cleanly when host not found in file' {
        InModuleScope VMDeployTools {
            $configFile = Join-Path $TestDrive 'config_no_target'
            Set-Content $configFile -Value @(
                'Host db01'
                '  HostName db01.vollminlab.com'
            )

            { Remove-HostBlockFromConfig -HostName 'web01' -ConfigPath $configFile } |
                Should -Not -Throw

            (Get-Content $configFile -Raw) | Should -Match 'db01'
        }
    }
}

# ===========================================================================
# Remove-HostFromKnownHosts
# ===========================================================================
Describe 'Remove-HostFromKnownHosts' -Tag 'Unit' {

    It 'Removes lines matching the hostname' {
        InModuleScope VMDeployTools {
            $kh = Join-Path $TestDrive 'known_hosts_remove'
            Set-Content $kh -Value @(
                'web01 ecdsa-sha2-nistp256 AAAAE2ecdsaAAA'
                'db01 ecdsa-sha2-nistp256 AAABB2ecdsaBBB'
            )

            Remove-HostFromKnownHosts -HostName 'web01' -KnownHostsPath $kh

            $result = Get-Content $kh
            $result | Should -Not -Match 'web01'
            $result | Should -Match 'db01'
        }
    }

    It 'Leaves all non-matching lines intact' {
        InModuleScope VMDeployTools {
            $kh = Join-Path $TestDrive 'known_hosts_intact'
            Set-Content $kh -Value @(
                'alpha ecdsa-sha2-nistp256 AAAAE2ecdsaAAA'
                'beta ecdsa-sha2-nistp256 AAABB2ecdsaBBB'
                'gamma ecdsa-sha2-nistp256 AAACC2ecdsaCCC'
            )

            Remove-HostFromKnownHosts -HostName 'beta' -KnownHostsPath $kh

            $result = Get-Content $kh -Raw
            $result | Should -Match 'alpha'
            $result | Should -Match 'gamma'
            $result | Should -Not -Match 'beta'
            ($result -split "`n" | Where-Object { $_ -match '\S' }).Count | Should -Be 2
        }
    }

    It 'Skips cleanly when file does not exist' {
        InModuleScope VMDeployTools {
            { Remove-HostFromKnownHosts -HostName 'web01' `
                -KnownHostsPath (Join-Path $TestDrive 'nosuchfile') } |
                Should -Not -Throw
        }
    }
}

# ===========================================================================
# Get-NetworkPortGroupFromIP (fallback mapping path)
# ===========================================================================
Describe 'Get-NetworkPortGroupFromIP' -Tag 'Unit' {

    BeforeAll {
        InModuleScope VMDeployTools {
            # Get-VDPortgroup only exists when VMware.VimAutomation.Vds is loaded.
            # Define a stub so Mock has something to override, then mock it to return
            # empty - forcing the auto-detect path to find nothing and fall back to
            # the hardcoded subnet map.
            if (-not (Get-Command Get-VDPortgroup -ErrorAction SilentlyContinue)) {
                function Get-VDPortgroup { param([string]$Name) }
            }
            Mock Get-VDPortgroup { return @() }
        }
    }

    It 'Returns 152-DPG-GuestNet for 192.168.152.x' {
        InModuleScope VMDeployTools {
            $result = Get-NetworkPortGroupFromIP -IPAddress '192.168.152.50'
            $result | Should -Be '152-DPG-GuestNet'
        }
    }

    It 'Returns 160-DPG-DMZ for 192.168.160.x' {
        InModuleScope VMDeployTools {
            $result = Get-NetworkPortGroupFromIP -IPAddress '192.168.160.10'
            $result | Should -Be '160-DPG-DMZ'
        }
    }

    It 'Throws for an unknown subnet' {
        InModuleScope VMDeployTools {
            { Get-NetworkPortGroupFromIP -IPAddress '10.0.0.1' } | Should -Throw
        }
    }
}

# ===========================================================================
# ConvertTo-SHA512Crypt
# ===========================================================================
Describe 'ConvertTo-SHA512Crypt' -Tag 'Unit' {

    It 'Output starts with $6$' {
        InModuleScope VMDeployTools {
            $secPw = ConvertTo-SecureString 'TestPassword123!' -AsPlainText -Force
            $result = ConvertTo-SHA512Crypt -Password $secPw
            $result | Should -Match '^\$6\$'
        }
    }

    It 'Output has at least four dollar-sign-delimited segments (format: $6$salt$hash)' {
        InModuleScope VMDeployTools {
            $secPw = ConvertTo-SecureString 'AnotherPassword99' -AsPlainText -Force
            $result = ConvertTo-SHA512Crypt -Password $secPw
            $parts = $result -split '\$'
            # ['', '6', salt, hash] -> at least 4 parts
            $parts.Count | Should -BeGreaterOrEqual 4
            $parts[1] | Should -Be '6'
            $parts[2].Length | Should -BeGreaterThan 0
            $parts[3].Length | Should -BeGreaterThan 0
        }
    }

    It 'Produces different output for different passwords' {
        InModuleScope VMDeployTools {
            $pw1 = ConvertTo-SHA512Crypt -Password (ConvertTo-SecureString 'Password1' -AsPlainText -Force)
            $pw2 = ConvertTo-SHA512Crypt -Password (ConvertTo-SecureString 'Password2' -AsPlainText -Force)
            $pw1 | Should -Not -Be $pw2
        }
    }
}

# ===========================================================================
# Add-SshConfigEntryLocal
# ===========================================================================
Describe 'Add-SshConfigEntryLocal' -Tag 'Unit' {

    Context 'Single config file' {

        It 'Writes Host block when host is not already present' {
            InModuleScope VMDeployTools {
                $configFile = Join-Path $TestDrive 'new_config'

                Add-SshConfigEntryLocal -HostName 'web01' `
                    -DnsName 'web01.vollminlab.com' `
                    -PublicKeyPath '~/.ssh/web01_id_ed25519.pub' `
                    -ConfigPaths @($configFile)

                $result = Get-Content $configFile -Raw
                $result | Should -Match 'Host web01'
                $result | Should -Match 'HostName web01\.vollminlab\.com'
            }
        }

        It 'Does not duplicate Host block when host already present' {
            InModuleScope VMDeployTools {
                $configFile = Join-Path $TestDrive 'existing_config'
                Set-Content $configFile -Value @(
                    'Host web01'
                    '  HostName web01.vollminlab.com'
                    '  User vollmin'
                    '  IdentitiesOnly yes'
                    '  IdentityFile ~/.ssh/web01_id_ed25519.pub'
                )

                Add-SshConfigEntryLocal -HostName 'web01' `
                    -DnsName 'web01.vollminlab.com' `
                    -PublicKeyPath '~/.ssh/web01_id_ed25519.pub' `
                    -ConfigPaths @($configFile)

                $occurrences = (Select-String -Path $configFile -Pattern '^Host web01$').Count
                $occurrences | Should -Be 1
            }
        }

        It 'Creates the config file if it does not exist' {
            InModuleScope VMDeployTools {
                $configFile = Join-Path $TestDrive 'brand_new_config'

                Add-SshConfigEntryLocal -HostName 'newhost' `
                    -DnsName 'newhost.vollminlab.com' `
                    -PublicKeyPath '~/.ssh/newhost_id_ed25519.pub' `
                    -ConfigPaths @($configFile)

                Test-Path $configFile | Should -Be $true
                (Get-Content $configFile -Raw) | Should -Match 'Host newhost'
            }
        }
    }

    Context 'Multiple config files' {

        It 'Writes the Host block to each file in ConfigPaths' {
            InModuleScope VMDeployTools {
                $configA = Join-Path $TestDrive 'multi_config_a'
                $configB = Join-Path $TestDrive 'multi_config_b'

                Add-SshConfigEntryLocal -HostName 'db01' `
                    -DnsName 'db01.vollminlab.com' `
                    -PublicKeyPath '~/.ssh/db01_id_ed25519.pub' `
                    -ConfigPaths @($configA, $configB)

                (Get-Content $configA -Raw) | Should -Match 'Host db01'
                (Get-Content $configB -Raw) | Should -Match 'Host db01'
            }
        }

        It 'Skips files where host already exists, writes to files where it does not' {
            InModuleScope VMDeployTools {
                $configA = Join-Path $TestDrive 'multi_skip_a'
                $configB = Join-Path $TestDrive 'multi_skip_b'

                # Pre-populate A with the entry
                Set-Content $configA -Value @(
                    'Host db01'
                    '  HostName db01.vollminlab.com'
                )

                Add-SshConfigEntryLocal -HostName 'db01' `
                    -DnsName 'db01.vollminlab.com' `
                    -PublicKeyPath '~/.ssh/db01_id_ed25519.pub' `
                    -ConfigPaths @($configA, $configB)

                # A should still have exactly one entry
                (Select-String -Path $configA -Pattern '^Host db01$').Count | Should -Be 1
                # B should now have one entry
                (Get-Content $configB -Raw) | Should -Match 'Host db01'
            }
        }
    }
}
