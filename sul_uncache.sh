        if redis-cli ping > /dev/null 2>&1;
        then
                redis-cli flushall > /dev/null;
                echo -e "$(tput setaf 2)\033[1mSuccess\033[0m: $(tput setaf 7)Redis cache flushed"
        fi
        if wp core version >/dev/null 2>&1;
        then
                wp cache flush > /dev/null;
                echo -e "$(tput setaf 2)\033[1mSuccess\033[0m: $(tput setaf 7)WP cache flushed"
                if ! rm -rf ./wp-content/cache/*;
                then
                        echo -e "$(tput setaf 1)\033[1mFailed\033[0m: $(tput setaf 7)Reset permissions and try again."
                else echo -e "$(tput setaf 2)\033[1mSuccess\033[0m: $(tput setaf 7)wp-content/cache removed"
                fi
        elif php bin/magento --version >/dev/null 2>&1;
        then
                php bin/magento cache:clean;
                php bin/magento cache:flush;
        elif php artisan --version >/dev/null 2>&1;
        then
                php artisan optimize:clear
        fi

################CLEARS CACHE FOR WEBSITE
