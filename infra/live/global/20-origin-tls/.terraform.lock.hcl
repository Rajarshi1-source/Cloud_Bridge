# This file is maintained automatically by "terraform init".
# Manual edits may be lost in future updates.

# cloudflare/cloudflare: zh (package SHA-256) hashes from the registry for linux_amd64, linux_arm64,
# darwin_arm64 and windows_amd64. Run `bash tools/dev/iac-check.sh lock` where GitHub release
# downloads work to add the h1 hashes.

provider "registry.terraform.io/cloudflare/cloudflare" {
  version     = "5.28.0"
  constraints = "~> 5.28.0"
  hashes = [
    "zh:216e03e0dd702f4be29280584290388c7fed0d4beb0a998f3c1229cb74166b7b",
    "zh:886714cfd9ada7876dd39ed857661766d9b75ba205079c3b70c4d5b56e9955b8",
    "zh:9c1893d4da37939a88b6286ae786d1293b160a63230b6dd396067593fd24eeb4",
    "zh:f8e00ec634b0e97adb664d04ea1ceb116e37eaf4b7a7e581f01e3c95ed1eb83c",
  ]
}

provider "registry.terraform.io/hashicorp/aws" {
  version     = "6.68.0"
  constraints = "~> 6.0"
  hashes = [
    "h1:79hHQtjGSCiXBZK+VDiNUdI2SLXbNaHf+CHySvKFnvA=",
    "h1:SyHeRgZ4GWMf6vrf/7MX8dvSkHCR8Wb4hSOyFDMz0sc=",
    "h1:rB2Amjxr32AZWeWsDMQyU61xmW8IvSAUXhv4ogvx9l4=",
    "h1:s5EXu9EtGfnLR3ebHoIyZBLRYMPcRL9zcfx/NKi+Q9o=",
    "zh:064ed007a33a22d8367db88b18d56a4dd066f07f95b1a4d80ffa2b6ee803f6f0",
    "zh:20ede4bb730b55023ad426ed13b1b4b295fac4bcc2baa4fb63d2932aa15d760d",
    "zh:490cffbc315ba21f740158a6b4195e7707ec2ee7ed357a47bb90ed18466f01a2",
    "zh:7840197f73f53d676373c9aeabccd79c61c6da6e4aa1ed840e57ca46c1894126",
    "zh:889b15a5c2f7fb168c04c846e75932a6b2ceb7967c3bfa0a0e24be16cdee7969",
    "zh:96ba7624b6f0e0a1fa5477b0838194be919d815d30ce7f97e04d4520cca4c00b",
    "zh:9b12af85486a96aedd8d7984b0ff811a4b42e3d88dad1a3fb4c0b580d04fa425",
    "zh:9b41c2afe2fec1a1880f9427b3ca611abfe6643b41942556a83cd7daae55acf1",
    "zh:a83e9d46de040fa7bc56f7aa53bdeb8d7078bac65d9155b07022fd75723308b8",
    "zh:aa5cfdd2faf8a2848c72c13ca88786b857fd397aa713967b8b1f9610f2c76a0b",
    "zh:abd449fbf38cf828b8b17bc8540752733dd861160504a45b411e72e1792c758c",
    "zh:b2511842cb6b23036c72babbaf12b4984835bb2824f938882330b51c68bdaecd",
    "zh:c11e8860c4d611dda93da2e5be27c9bd2599da6ad320f3d12ccc714ffbe6f100",
    "zh:e4252ceda8641bfe85ad7710b428f994c080bde6c55043ab47a08015432cebdc",
    "zh:f292ad91c97ac7354a04a698f346c2a0c3866d9170ca45dda6a6bfab71180be0",
    "zh:f4d293cd0e9562bfa1ba32a1fe5c3652c6a32b951e44081158737d4075696045",
  ]
}

provider "registry.terraform.io/hashicorp/google" {
  version     = "7.46.1"
  constraints = "~> 7.0"
  hashes = [
    "h1:BMf5TKc4/U6JTUCyY7bM+VtfKfCU7lT1BewErfS8RNw=",
    "h1:Hgv4BX9846ucZ6XcEql0DPfACoXqlcLat9SjUAn7YLI=",
    "h1:oaPjmiPJz4rtO1CCcQ53YsY+Xr/vUEvmYRz10SGieuk=",
    "h1:vLRcwq7JBzozALBtMF9Ij5a4ylGa6XtRUaW53CsiTMA=",
    "zh:2e0e513915988d80582f8db7ff18c6242b8f4fad977d428feb11bcbd30d8ba95",
    "zh:44ebe20d2a548c4318cc75497b7de0ded4bcb5867dbc9d7418f1941d5f6c5c2c",
    "zh:48016a7ad372f27aa44b4f4611eb24fc634b05b0c25b84ca55a359f525f5a36f",
    "zh:726fc1bbacf317bf946b53adc71248f890f78ede639c7d9e6fc52716668fd0ef",
    "zh:9944d3128c69217d976844d936dd642d07140412d56e04bada95da189be37bdb",
    "zh:a77548865bd320243641389763d3696b05c540d1cbb9868b249371626bab4132",
    "zh:af6a79150120844c45236dd8d0e39fec76ef50528f5de9a623acbfb96108e4b8",
    "zh:c1f3a7b1652db3a9f429cb749e9a4a3efcbf980d9d90f2634f25973931f2eedc",
    "zh:d18255642cae2f00cf5a2946652a17cbf59a0d65c56bc0aac31d2509a360000e",
    "zh:df3a71bf6d245a9f7c6548680055c22ecc8432f664b3d93d2ea0363f4c4d56ad",
    "zh:e406cc8194485420bee42af19e3a545272a5ce45bc9ce7d5ac4438fb1a3f6fc6",
    "zh:f569b65999264a9416862bca5cd2a6177d94ccb0424f3a4ef424428912b9cb3c",
  ]
}

provider "registry.terraform.io/hashicorp/tls" {
  version     = "4.4.1"
  constraints = "~> 4.1"
  hashes = [
    "h1:1Zk4TqZwWmUZHfGTtM/vw8EKoWecYboMRqwhNaoTopc=",
    "h1:BHiQRPHBNJKfcr+kzFko7BZ2wWqsDx4U8A0MPDQRbPk=",
    "h1:WOqocV4RLbVA6NX+7Pw3Y4FShzAKSBtEQHHMs+0JSuQ=",
    "h1:x0sq38+DvTpCH55KdhERVDgNjHL036y4i+DITul45TA=",
    "zh:0855f9a980426a0af2c4415fb23cccbbb88c2d1dd40d83da6f45622c075b398b",
    "zh:189227fdae28e547b1d988f5d83c4280fce02e3152d8b62aa810047e2f9f7e59",
    "zh:2557db4f493aa90b3683905d9eeb103e55a3facc4ccda763d6de6025116ae121",
    "zh:2cfd8d6a543ac61c6e7c0461839ab89bb8da1ba6c8090ab946b1cf47f100d7fa",
    "zh:5c04cf2a683ea60a0072c59bbcf415f232c382c891b3aaeb9bbbb28213e0d878",
    "zh:6681e35d50328bc11a49bb61c002121353f6a844cc6d63a0c3db57745ec38a56",
    "zh:693b810e438bb1dfbc13a42629597284ac1eb08eb30f46f18738d7a9bb768d34",
    "zh:77c4425f75346b23817837f3947b6ab7e765308abbf573fec5d2cafd4b82f142",
    "zh:b3fd64ec1cecea98c88d2332dbeac40498ce2506e3235bdbd1afdfbaa47bb758",
    "zh:c06224b5797b129a84e2514be43f2b140622928fe9c92b55d7941be3296ea289",
    "zh:debc830ec123f27944c6170d76cb4ea3542845896960bb9fc530702774df328e",
    "zh:f300fcc909014550fd74b2b751665dcc049f874e7a475903f65671baf2c2d86d",
    "zh:f569b65999264a9416862bca5cd2a6177d94ccb0424f3a4ef424428912b9cb3c",
  ]
}
