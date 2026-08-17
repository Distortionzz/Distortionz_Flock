fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Distortionz'
description 'Server-authoritative ALPR camera network for the Distortionz stack'
version '1.1.0'
repository 'https://github.com/Distortionzz/Distortionz_Flock'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua'
}

client_scripts {
    'client.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'version_check.lua',
    'server.lua'
}

dependencies {
    'ox_lib',
    'oxmysql'
}
