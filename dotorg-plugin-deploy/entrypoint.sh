#!/bin/bash

# Note that this does not use pipefail
# because if the grep later doesn't match any deleted files,
# which is likely the majority case,
# it does not exit with a 0, and I only care about the final exit.
set -eo

# Ensure SVN username and password are set
# IMPORTANT: while secrets are encrypted and not viewable in the GitHub UI,
# they are by necessity provided as plaintext in the context of the Action,
# so do not echo or use debug mode unless you want your secrets exposed!
if [[ -z "$SVN_USERNAME" ]]; then
	echo "Set the SVN_USERNAME secret"
	exit 1
fi

if [[ -z "$SVN_PASSWORD" ]]; then
	echo "Set the SVN_PASSWORD secret"
	exit 1
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
	echo "Set the GITHUB_TOKEN env variable"
	exit 1
fi

# Allow some ENV variables to be customized
if [[ -z "$SLUG" ]]; then
	SLUG=${GITHUB_REPOSITORY#*/}
fi
echo "ℹ︎ SLUG is $SLUG"

# Does it even make sense for VERSION to be editable in a workflow definition?
if [[ -z "$VERSION" ]]; then
	VERSION=${GITHUB_REF#refs/tags/}
fi
echo "ℹ︎ VERSION is $VERSION"

if [[ -z "$ASSETS_DIR" ]]; then
	ASSETS_DIR=".wordpress-org"
fi
echo "ℹ︎ ASSETS_DIR is $ASSETS_DIR"

SVN_URL="http://plugins.svn.wordpress.org/${SLUG}/"
SVN_DIR="/github/svn-${SLUG}"

# Checkout just trunk and assets for efficiency
# Tagging will be handled on the SVN level
echo "➤ Checking out .org repository…"
svn checkout --depth immediates "$SVN_URL" "$SVN_DIR"
cd "$SVN_DIR"
svn update --set-depth infinity assets
svn update --set-depth infinity trunk

echo "➤ Copying files…"
cd "$GITHUB_WORKSPACE"

# "Export" a cleaned copy to a temp directory
TMP_DIR="/github/archivetmp"
mkdir "$TMP_DIR"

git config --global --add safe.directory "*"
git config --global user.email "pierre@lannoy.fr"
git config --global user.name "Pierre Lannoy"

# If there's no .gitattributes file, write a default one into place
if [[ ! -e "$GITHUB_WORKSPACE/.gitattributes" ]]; then
	cat > "$GITHUB_WORKSPACE/.gitattributes" <<-EOL
	/$ASSETS_DIR export-ignore
	/.gitattributes export-ignore
	/.gitignore export-ignore
	/.github export-ignore
	EOL

	# Ensure we are in the $GITHUB_WORKSPACE directory, just in case
	# The .gitattributes file has to be committed to be used
	# Just don't push it to the origin repo :)
	git add .gitattributes && git commit -m "Add .gitattributes file"
fi

# This will exclude everything in the .gitattributes file with the export-ignore flag
git archive HEAD | tar x --directory="$TMP_DIR"

cd "$SVN_DIR"

# Copy from clean copy to /trunk, excluding dotorg assets
# The --delete flag will delete anything in destination that no longer exists in source
rsync -rc "$TMP_DIR/" trunk/ --delete

# Copy dotorg assets to /assets
rsync -rc "$GITHUB_WORKSPACE/$ASSETS_DIR/" assets/ --delete

# Add everything and commit to SVN
# The force flag ensures we recurse into subdirectories even if they are already added
# Suppress stdout in favor of svn status later for readability
echo "➤ Preparing files…"
svn add . --force > /dev/null

# SVN delete all deleted files
# Also suppress stdout here
svn status | grep '^\!' | sed 's/! *//' | xargs -I% svn rm --force % > /dev/null

# If it's a full release i.e. tag like "1.0.0" and not like "1.0.0-rc1",
# then copy tag before commiting
if [[ $VERSION != *"-"* ]];then
    echo "➤ Copying tag…"
    svn cp "trunk" "tags/$VERSION"
fi

svn status

echo "➤ Committing files…"
#svn commit -m "$NAME $VERSION released from GitHub" --no-auth-cache --non-interactive  --username "$SVN_USERNAME" --password "$SVN_PASSWORD"

echo "✓ Plugin deployed!"

# If it's a full release i.e. tag like "1.0.0" and not like "1.0.0-rc1",
# then generate a zip
#if [[ $VERSION != *"-"* ]];then
    echo "➤ Generating zip file…"
    ln -s "${SVN_DIR}/trunk" "${SVN_DIR}/${SLUG}"
    zip -r "${GITHUB_WORKSPACE}/${SLUG}-${VERSION}.zip" "$SLUG"
    echo "zip_file=${SLUG}-${VERSION}.zip" >> "${GITHUB_OUTPUT}"
    echo "✓ Zip file generated!"
#fi


