#!/bin/sh
set -eu

# Send errors to stderr so stdout contains only speed/price pairs.
fail() {
    echo "$*" >&2
    exit 1
}

# Deno runs the ALTCHA solver; jq builds requests and reads JSON responses.
for tool in jq curl deno; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        fail "$tool is required."
    fi
done

ADDRESS=${1:-}
if [ -z "$ADDRESS" ]; then
    fail 'Please provide an address.'
fi

BASE_URL=https://bahnhof.se
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Give each run its own cookies and response files, and remove them on exit.
WORK_DIR=$(mktemp -d)
COOKIE_JAR="$WORK_DIR/cookies"
PAGE_FILE="$WORK_DIR/page"
PAYLOAD_FILE="$WORK_DIR/payload"
RESPONSE_FILE="$WORK_DIR/response"
trap 'rm -rf "$WORK_DIR"' EXIT
trap 'exit 1' HUP INT TERM

# Open the order page to establish a session before calling the JSON API.
page_status=$(curl -sS -L \
    --connect-timeout 15 --max-time 60 \
    -c "$COOKIE_JAR" \
    -G --data-urlencode "search=$ADDRESS" \
    -o "$PAGE_FILE" -w '%{http_code}' \
    "$BASE_URL/bestall/bredband") || fail 'Could not load the Bahnhof order page.'

# The HTML page may itself require proof of work. Decode its embedded challenge,
# solve it, and retry once with the same session cookies.
if [ "$page_status" = 428 ] || [ "$page_status" = 429 ]; then
    page_token=$(
        sed -n 's/.*data-challenge="\([^"]*\)".*/\1/p' "$PAGE_FILE" |
            sed 's/&quot;/"/g; s/&#039;/'"'"'/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g' |
            deno run --no-config "$SCRIPT_DIR/solveAltcha.ts"
    ) || fail 'Could not solve the initial page challenge.'

    page_status=$(curl -sS -L \
        --connect-timeout 15 --max-time 60 \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -H "X-Altcha: $page_token" \
        -G --data-urlencode "search=$ADDRESS" \
        -o "$PAGE_FILE" -w '%{http_code}' \
        "$BASE_URL/bestall/bredband") || fail 'Could not load the Bahnhof order page after ALTCHA.'
fi

[ "$page_status" = 200 ] || fail "Bahnhof order page returned HTTP $page_status."

# API requests must use the CSRF token belonging to the session above.
CSRF_TOKEN=$(sed -n 's/.*<meta name="csrf-token" id="csrf-token" content="\([^"]*\).*/\1/p' "$PAGE_FILE")
[ -n "$CSRF_TOKEN" ] || fail 'Bahnhof did not supply a CSRF token.'

# POST JSON and return a successful JSON response. A challenged request gets one
# retry with its signed proof of work; other failures stop the price lookup.
request() {
    endpoint=$1
    payload=$2
    altcha_token=
    challenge_retried=0

    # A file preserves UTF-8 payload bytes when passing them to curl.
    printf '%s' "$payload" > "$PAYLOAD_FILE"

    while :; do
        status=$(curl -sS \
            --connect-timeout 15 --max-time 60 \
            -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
            -H 'Content-Type: application/json' \
            -H 'X-Requested-With: XMLHttpRequest' \
            -H "X-CSRF-TOKEN: $CSRF_TOKEN" \
            -H "X-Altcha: $altcha_token" \
            --data-binary "@$PAYLOAD_FILE" \
            -o "$RESPONSE_FILE" -w '%{http_code}' \
            "$BASE_URL$endpoint") || fail "Request to $endpoint failed."

        # Only treat 428/429 as a solvable challenge if challenge data is present.
        if [ "$challenge_retried" -eq 0 ] &&
            { [ "$status" = 428 ] || [ "$status" = 429 ]; } &&
            jq -e '.data.altcha.parameters and .data.altcha.signature' "$RESPONSE_FILE" >/dev/null 2>&1; then
            altcha_token=$(
                jq -c '.data.altcha' "$RESPONSE_FILE" |
                    deno run --no-config "$SCRIPT_DIR/solveAltcha.ts"
            ) || fail 'Could not solve ALTCHA challenge.'

            challenge_retried=1
            continue
        fi

        case "$status" in
            2??) ;;
            *) fail "Bahnhof request to $endpoint returned HTTP $status." ;;
        esac

        # Reject HTML, malformed JSON, and API errors before extracting data.
        jq -e '.status == "ok"' "$RESPONSE_FILE" >/dev/null 2>&1 ||
            fail "Invalid or unsuccessful Bahnhof response for $endpoint."

        cat "$RESPONSE_FILE"
        return
    done
}

# Let jq escape the address, including quotes and other special characters.
ADDRESS_PAYLOAD=$(jq -cn --arg address "$ADDRESS" '{address:$address}')
NETWORKS_RESPONSE=$(request /ajax/search/networks "$ADDRESS_PAYLOAD")

# Exit 2 distinguishes missing coverage from an unexpected lookup failure.
if [ "$(printf '%s' "$NETWORKS_RESPONSE" | jq -r '.data.type')" = COVERAGE_NOT_FOUND ]; then
    echo "Coverage not found for address: $ADDRESS" >&2
    exit 2
fi

# Translate the network lookup fields into the products endpoint's request shape.
NETWORK_PAYLOAD=$(
    printf '%s' "$NETWORKS_RESPONSE" | jq -ce '
        .data.networks
        | select(type == "array" and length > 0)
        | {networks: map({city, network: .name, id})}
    '
) || fail 'Bahnhof returned no networks.'

PRODUCTS_RESPONSE=$(request /ajax/bredband/products "$NETWORK_PAYLOAD")

# Keep broadband products and their regular recurring prices, excluding setup fees
# and temporary promotions. Validate all prices before emitting any output.
PRICES=$(
    printf '%s' "$PRODUCTS_RESPONSE" | jq -er '
        .data.products
        | select(type == "array")
        | [.[] | select(.category.type == "BB") | {
            speed: (.title | sub(" Mbit/s$"; "")),
            price: .prices.regularPrice
        }]
        | select(length > 0)
        | if all(.[]; (.price | type) == "number") then
            .[] | "\(.speed) \(.price)"
          else
            error("Missing broadband price")
          end
    '
) || fail 'Bahnhof returned no valid broadband prices.'

# comparePrices.sh expects one line per product, for example: 1000/1000 529.
printf '%s\n' "$PRICES"
