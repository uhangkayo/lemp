#!/bin/bash

set -e

# Colours
red=$'\e[1;31m'
grn=$'\e[1;32m'
yel=$'\e[1;33m'
blu=$'\e[1;34m'
mag=$'\e[1;35m'
cyn=$'\e[1;36m'
end=$'\e[0m'

# Install Let's Encrypt (Certbot)
install_letsencrypt() {
    echo "${grn}Installing Let's Encrypt (Certbot)...${end}"
    echo ""
    sleep 3
    
    # Update package list
    apt update
    
    # Try to install certbot via snap (recommended method)
    echo "${yel}Attempting to install certbot via snap...${end}"
    
    if apt install snapd -y && snap install core && snap refresh core && snap install --classic certbot; then
        echo "${grn}Certbot installed successfully via snap${end}"
        
        # Create symbolic link for certbot command
        ln -sf /snap/bin/certbot /usr/bin/certbot
        
        # Install certbot nginx plugin
        snap set certbot trust-plugin-with-root=ok
        snap install certbot-dns-cloudflare 2>/dev/null || true
        
    else
        echo "${yel}Snap installation failed. Trying alternative installation method...${end}"
        
        # Alternative installation using apt (fallback method)
        echo "${yel}Installing certbot via apt package manager...${end}"
        
        if apt install -y certbot python3-certbot-nginx; then
            echo "${grn}Certbot installed successfully via apt${end}"
        else
            echo "${red}Both snap and apt installation methods failed${end}"
            return 1
        fi
    fi
    
    # Create directory for SSL certificates
    mkdir -p /etc/letsencrypt
    mkdir -p /var/log/letsencrypt
    
    # Set proper permissions
    chmod 755 /etc/letsencrypt
    chmod 755 /var/log/letsencrypt
    
    # Configure automatic renewal
    echo "${grn}Setting up automatic certificate renewal...${end}"
    
    # Add cron job for automatic renewal
    (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
    
    # Test certbot installation
    if certbot --version >/dev/null 2>&1; then
        echo "${grn}Let's Encrypt (Certbot) installed successfully!${end}"
        echo "${yel}To obtain SSL certificates, run: certbot --nginx -d yourdomain.com${end}"
        echo "${yel}Automatic renewal is configured via cron job${end}"
    else
        echo "${red}Let's Encrypt installation failed${end}"
        return 1
    fi
    
    echo ""
    echo "${grn}Let's Encrypt installation completed${end}"
    echo "${yel}Note: You'll need to configure your domain and obtain certificates manually${end}"
    echo "${yel}Example: certbot --nginx -d example.com -d www.example.com${end}"
    echo ""
    sleep 1
}

# Run the installation
install_letsencrypt