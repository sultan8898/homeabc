#!/bin/bash

######################################################################
######################IMPORTANT NOTE:#################################
######################################################################
#DO REFERESH THE PERMISSIONS FROM APPLCIATIONS TAB 
#DO RUN wp-redis activate --force--allow-root < if it does not run by itself. 

# Part 1: Extract and save 4 letters to 1_random_redis_file.txt
cd ../conf
content=$(cat server.nginx)
extracted=$(echo $content | grep -oP '(?<=-)[0-9]*(?=.cloudwaysapps.com)')
last_four=${extracted: -4}

if [[ ${last_four:0:1} -eq 0 ]]; then
    last_four=${extracted: -5}
fi

cd ../public_html
echo $last_four > 1_random_redis_file.txt

# Part 2: Update wp-config.php
FILE_PATH="./wp-config.php"
TEMP_FILE=$(mktemp)

read -r -d '' CODE_TO_ADD <<EOF
define( 'WP_REDIS_CONFIG', [
   'token' => "e279430effe043b8c17d3f3c751c4c0846bc70c97f0eaaea766b4079001c",
   'host' => '127.0.0.1',
   'port' => 6379,
   'database' => $last_four, 
   'timeout' => 2.5,
   'read_timeout' => 2.5,
   'split_alloptions' => true,
   'async_flush' => true,
   'client' => 'phpredis', 
   'compression' => 'zstd', 
   'serializer' => 'igbinary', 
   'prefetch' => true, 
   'debug' => false,
   'save_commands' => false,
   'prefix' => DB_NAME,  
] );
define( 'WP_REDIS_DISABLED', false );
EOF

if grep -Fxq "$CODE_TO_ADD" $FILE_PATH; then
    echo "Code is present. No changes made."
else
    echo "Code is not present. Adding the code."
    awk -v code="$CODE_TO_ADD" '/\/\* That'\''s all, stop editing! Happy blogging. \*\//{print code; print; next}1' $FILE_PATH > $TEMP_FILE && mv $TEMP_FILE $FILE_PATH
fi

# Part 3: Install mu-plugin
public_html_dir='.'
mu_plugins_dir="$public_html_dir/wp-content/mu-plugins"
file_name='redis-cache-pro.php'
dir_name='redis-cache-pro'
zip_url='https://objectcache.pro/plugin/redis-cache-pro.zip?token=e279430effe043b8c17d3f3c751c4c0846bc70c97f0eaaea766b4079001c'
symlink_target='/home/.code/redis-cache-pro'

if [ ! -d "$mu_plugins_dir" ]; then
    mkdir -p "$mu_plugins_dir"
fi

cd "$mu_plugins_dir"

if [ ! -e "$file_name" ] && [ ! -e "$dir_name" ]; then
    wget -O redis-cache-pro.zip "$zip_url"
    unzip -o redis-cache-pro.zip

    cat << 'PHP' > "$file_name"
<?php
/*
 * Plugin Name: Object Cache Pro (MU)
 * Plugin URI: https://objectcache.pro
 * Description: A business class Redis object cache backend for WordPress.
 * Version: 1.20.0
 * Author: Rhubarb Group
 * Author URI: https://rhubarb.group
 * License: Proprietary
 * Requires PHP: 7.2
 */
defined('ABSPATH') || exit;
define('RedisCachePro\Basename', basename(__FILE__));
foreach ([
    defined('WP_REDIS_DIR') ? rtrim(WP_REDIS_DIR, '/') : null,
    __DIR__ . '/redis-cache-pro',
    __DIR__ . '/object-cache-pro',
] as $path) {
    if (is_null($path)) {
        continue;
    }
    foreach (['redis-cache-pro.php', 'object-cache-pro.php'] as $file) {
        if (is_readable("{$path}/{$file}") && include_once "{$path}/{$file}") {
            return;
        }
    }
}
error_log('objectcache.critical: Failed to locate and load Object Cache Pro plugin');
if (defined('WP_DEBUG') && WP_DEBUG) {
    throw new RuntimeException('Failed to locate and load Object Cache Pro plugin');
}
PHP

    ln -s "$dir_name" "$symlink_target"
fi

# Cleanup: Delete 1_random_redis_file.txt
rm -f 1_random_redis_file.txt

# Run wp redis activate
wp redis activate --force --allow-root
