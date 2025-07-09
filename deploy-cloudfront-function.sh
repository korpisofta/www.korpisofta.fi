#!/bin/bash

# CloudFront Function Deployment Script
set -e

# Check required tools
command -v aws >/dev/null 2>&1 || { echo "Error: AWS CLI is required but not installed." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed." >&2; exit 1; }

FUNCTION_NAME="url-rewrite-index"

# to list distributions, run:
# aws cloudfront list-distributions --query 'DistributionList.Items[*].[Id,DomainName]' --output table
DISTRIBUTION_ID="${DISTRIBUTION_ID:-EU8IB7Y0B67Y6}"

echo "Checking if function already exists..."
if aws cloudfront describe-function --name "$FUNCTION_NAME" >/dev/null 2>&1; then
    echo "Function '$FUNCTION_NAME' already exists. Updating..."
    FUNCTION_ARN=$(aws cloudfront describe-function --name "$FUNCTION_NAME" --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text)

    # Update the function code
    aws cloudfront update-function \
        --name "$FUNCTION_NAME" \
        --function-config Comment="Rewrite URLs to append index.html",Runtime=cloudfront-js-1.0 \
        --function-code fileb://cloudfront-function.js \
        --if-match $(aws cloudfront describe-function --name "$FUNCTION_NAME" --query 'ETag' --output text)

    echo "Function updated with ARN: $FUNCTION_ARN"
else
    echo "Creating CloudFront Function..."
    FUNCTION_ARN=$(aws cloudfront create-function \
        --name "$FUNCTION_NAME" \
        --function-config Comment="Rewrite URLs to append index.html",Runtime=cloudfront-js-1.0 \
        --function-code fileb://cloudfront-function.js \
        --query 'FunctionSummary.FunctionMetadata.FunctionARN' \
        --output text)

    echo "Function created with ARN: $FUNCTION_ARN"
fi

echo "Testing function..."
# Create test event JSON
cat > test-event.json << 'EOF'
{
    "version": "1.0",
    "context": {"eventType": "viewer-request"},
    "viewer": {"ip": "198.51.100.1"},
    "request": {
        "method": "GET",
        "uri": "/en/",
        "headers": {},
        "cookies": {},
        "querystring": {}
    }
}
EOF

aws cloudfront test-function \
    --name "$FUNCTION_NAME" \
    --if-match $(aws cloudfront describe-function --name "$FUNCTION_NAME" --query 'ETag' --output text) \
    --event-object fileb://test-event.json

# Clean up test file
rm -f test-event.json

echo "Publishing function..."
aws cloudfront publish-function \
    --name "$FUNCTION_NAME" \
    --if-match $(aws cloudfront describe-function --name "$FUNCTION_NAME" --query 'ETag' --output text)

echo "Function deployed successfully!"
echo "Function ARN: $FUNCTION_ARN"
echo ""

echo "Getting current distribution config..."
aws cloudfront get-distribution-config --id $DISTRIBUTION_ID > dist-config-full.json

# Extract just the DistributionConfig part and the ETag
jq '.DistributionConfig' dist-config-full.json > dist-config.json
ETAG=$(jq -r '.ETag' dist-config-full.json)

echo "Adding function association to distribution config..."
# Check if FunctionAssociations already exists and preserve existing ones
jq --arg function_arn "$FUNCTION_ARN" '
  if .DefaultCacheBehavior.FunctionAssociations then
    # Handle case where FunctionAssociations exists but Items might be null
    if (.DefaultCacheBehavior.FunctionAssociations.Items // [] | any(.FunctionARN == $function_arn)) then
      # Function already associated, no changes needed
      .
    else
      # Add our function to existing associations (or create if Items is null)
      .DefaultCacheBehavior.FunctionAssociations.Items = ((.DefaultCacheBehavior.FunctionAssociations.Items // []) + [{
        "EventType": "viewer-request",
        "FunctionARN": $function_arn
      }]) |
      .DefaultCacheBehavior.FunctionAssociations.Quantity = (.DefaultCacheBehavior.FunctionAssociations.Items | length)
    end
  else
    # No existing function associations, create new
    .DefaultCacheBehavior.FunctionAssociations = {
      "Quantity": 1,
      "Items": [
        {
          "EventType": "viewer-request",
          "FunctionARN": $function_arn
        }
      ]
    }
  end
' dist-config.json > dist-config-modified.json

# Check if any changes were made
if cmp -s dist-config.json dist-config-modified.json; then
    echo "Function is already associated with the distribution. No changes needed."
    rm -f dist-config-full.json dist-config.json dist-config-modified.json
    echo "Script completed successfully!"
    exit 0
fi

echo "Updating CloudFront distribution..."
if aws cloudfront update-distribution \
    --id $DISTRIBUTION_ID \
    --distribution-config file://dist-config-modified.json \
    --if-match "$ETAG" >/dev/null 2>&1; then
    echo "Distribution updated successfully!"
else
    echo "Error: Failed to update distribution. This might be due to:"
    echo "  - Distribution is already being updated"
    echo "  - ETag mismatch (distribution was modified by another process)"
    echo "  - Invalid configuration"
    exit 1
fi

echo "Cleaning up temporary files..."
rm -f dist-config-full.json dist-config.json dist-config-modified.json

echo "Distribution updated successfully! The function is now associated with your distribution."
echo "It may take a few minutes for the changes to propagate to all edge locations."
