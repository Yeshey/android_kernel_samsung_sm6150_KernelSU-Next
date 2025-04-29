#!/bin/bash

# Get the directory containing the script and the parent directory
DIR=$(readlink -f .)
PARENT_DIR=$(readlink -f "${DIR}/..") # Use quotes for safety

ARGS="$*"
DEVICE_MODEL="$1"

JOBS=$(nproc --all)

# Define Make parameters - Rely on PATH setup by the GitHub Action's toolchain() step
# LLVM=1 tells the build system to use LLVM/Clang tools.
# CC=clang explicitly sets the C compiler.
# CLANG_TRIPLE helps Clang target the correct architecture.
# CROSS_COMPILE_ARM32 is needed for building 32-bit components if any.
# Removed the explicit CROSS_COMPILE pointing to the wrong GCC path.
MAKE_PARAMS="-j${JOBS} ARCH=arm64 O=out LLVM=1 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-"

# --- Function to check device model and set config ---
devicecheck() {
    if [ "$DEVICE_MODEL" == "a70q" ]; then
        DEVICE_NAME="a70q"
        ZIP_NAME="${DEVICE_NAME}_KSU-Next_$(date +%d%m%y)" # Use curly braces for clarity
        DEFCONFIG=a70q_defconfig
    elif [ "$DEVICE_MODEL" == "a70s" ]; then
        DEVICE_NAME="a70s"
        ZIP_NAME="${DEVICE_NAME}_KSU-Next_$(date +%d%m%y)" # Use curly braces for clarity
        DEFCONFIG=a70q_defconfig # Note: Still using a70q_defconfig as per original script
    else
        echo "- Device model '$DEVICE_MODEL' not recognized or config not found"
        exit 1 # Exit with error code
    fi
    echo "- Device: $DEVICE_NAME"
    echo "- Defconfig: $DEFCONFIG"
    echo "- Zip Name: $ZIP_NAME"
}

# --- Function to ensure AnyKernel3 exists ---
anykernel3() {
	local ak3_dir="$PARENT_DIR/AnyKernel3"
	if [ -d "$ak3_dir" ]; then
		echo "- Found existing AnyKernel3 directory. Resetting..."
		cd "$ak3_dir" || exit 1 # Exit if cd fails
		git reset HEAD --hard
		git clean -fdx # Clean untracked files too
		cd "$DIR" || exit 1
	else
		echo "- Cloning AnyKernel3..."
	    git clone --depth=1 --branch a70 https://github.com/DerGoogler/AnyKernel3-A70-KSU_Next.git "$ak3_dir" || exit 1 # Exit if clone fails
	    cd "$DIR" || exit 1
	fi
}

# --- Function to create the flashable zip ---
makezipfile() {
	local ak3_dir="$PARENT_DIR/AnyKernel3"
	local kernel_image="out/arch/arm64/boot/Image.gz-dtb" # Use variable

	if [ ! -f "$kernel_image" ]; then
		echo "- Kernel image $kernel_image not found! Build likely failed."
		exit 1
	fi

    echo "- Copying kernel image to AnyKernel3..."
    cp "$kernel_image" "$ak3_dir/" || exit 1

    echo "- Creating zip file..."
    cd "$ak3_dir" || exit 1
    # Remove old zip if it exists
    rm -f "${DIR}/${ZIP_NAME}.zip"
    # Create new zip
    zip -r9 "${DIR}/${ZIP_NAME}.zip" . -x '*.git*' '*patch*' '*ramdisk*' 'README.md' '*modules*' || exit 1 # Zip into the kernel dir for easy upload
    cd "$DIR" || exit 1
    echo "- Zip created: ${ZIP_NAME}.zip"
}

# --- Main Build Process ---
echo "Starting Building ..."

# 1. Check device and set config
devicecheck

# 2. Toolchain PATH setup is handled by the GitHub Action workflow 'Fetch ToolChain' step

# 3. Apply defconfig
echo "- Applying defconfig: $DEFCONFIG"
# Note: Removed incorrect CROSS_COMPILE and REAL_CC overrides here. MAKE_PARAMS handles it.
make $MAKE_PARAMS $DEFCONFIG || { echo "- Defconfig failed!"; exit 1; }

# 4. Build the kernel
echo "- Building kernel ($MAKE_PARAMS)..."
# Note: Removed incorrect CROSS_COMPILE and REAL_CC overrides here. MAKE_PARAMS handles it.
make $MAKE_PARAMS || { echo "- Kernel build failed!"; exit 1; }

# 5. Prepare AnyKernel3
anykernel3

# 6. Create flashable zip
makezipfile

echo "- Build finished successfully!"
exit 0