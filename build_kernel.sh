#!/bin/bash

# Get the directory containing the script and the parent directory
# Ensure KERNEL_DIR is the current directory where the script is run from
KERNEL_DIR=$(pwd)
PARENT_DIR=$(dirname "$KERNEL_DIR") # Use dirname to get parent

# Arguments and device setup
ARGS="$*"
DEVICE_MODEL="$1"

JOBS=$(nproc --all)

# --- Toolchain Environment Variables (Should be set by GitHub Actions PATH setup) ---
# Make sure CC, CLANG_TRIPLE, CROSS_COMPILE_ARM32, etc. are available in the environment
# For local testing, you might need to export them manually:
# export PATH="$PARENT_DIR/Prebuilts/los-clang/bin:$PARENT_DIR/Prebuilts/gcc64/bin:$PARENT_DIR/Prebuilts/gcc32/bin:$PATH"
# export CLANG_TRIPLE="aarch64-linux-gnu-"
# export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"

# Define Make parameters
# Use LD=ld.lld explicitly if needed, but usually LLVM=1 handles it with PATH setup
# Removed CROSS_COMPILE= since Clang uses CLANG_TRIPLE for aarch64
MAKE_PARAMS="-j${JOBS} ARCH=arm64 O=out LLVM=1 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi-"
# Optional: If you still face assembler issues with clang, try adding LLVM_IAS=0
# MAKE_PARAMS="-j${JOBS} ARCH=arm64 O=out LLVM=1 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- LLVM_IAS=0"


# --- Function to check device model and set config ---
devicecheck() {
    if [ "$DEVICE_MODEL" == "a70q" ]; then
        DEVICE_NAME="a70q"
        # Use consistent naming for the zip file artifact
        ZIP_NAME="${DEVICE_NAME}_KSU-Next_$(date +%Y%m%d-%H%M)" # More unique name
        DEFCONFIG=a70q_defconfig
    elif [ "$DEVICE_MODEL" == "a70s" ]; then
        DEVICE_NAME="a70s"
        ZIP_NAME="${DEVICE_NAME}_KSU-Next_$(date +%Y%m%d-%H%M)" # More unique name
        DEFCONFIG=a70s_defconfig # *** USE a70s_defconfig FOR a70s ***
    else
        echo "- Device model '$DEVICE_MODEL' not recognized or config not found"
        exit 1 # Exit with error code
    fi
    echo "- Device: $DEVICE_NAME"
    echo "- Defconfig: $DEFCONFIG"
    echo "- Zip Name: $ZIP_NAME"
}

# --- Function to ensure AnyKernel3 exists ---
# (Keep your existing anykernel3 function, it looks fine)
anykernel3() {
	local ak3_dir="$PARENT_DIR/AnyKernel3"
	if [ -d "$ak3_dir" ]; then
		echo "- Found existing AnyKernel3 directory. Resetting..."
		cd "$ak3_dir" || exit 1 # Exit if cd fails
		git reset HEAD --hard --quiet
		git clean -fdx --quiet # Clean untracked files too
		cd "$KERNEL_DIR" || exit 1
	else
		echo "- Cloning AnyKernel3..."
	    git clone --depth=1 --branch master https://github.com/DerGoogler/AnyKernel3-A70-KSU_Next.git "$ak3_dir" || exit 1 # Exit if clone fails
	    cd "$KERNEL_DIR" || exit 1
	fi
}


# --- Function to create the flashable zip ---
makezipfile() {
	local ak3_dir="$PARENT_DIR/AnyKernel3"
	local kernel_image="out/arch/arm64/boot/Image.gz-dtb"
	local module_dest_dir_vendor="$ak3_dir/modules/vendor/lib/modules" # Standard path in AK3 for vendor modules
	local module_dest_dir_system="$ak3_dir/modules/system/lib/modules" # Standard path in AK3 for system modules (less common)

	if [ ! -f "$kernel_image" ]; then
		echo "- Kernel image $kernel_image not found! Build likely failed."
		exit 1
	fi

    echo "- Copying kernel image to AnyKernel3..."
    cp "$kernel_image" "$ak3_dir/" || exit 1

    echo "- Copying modules to AnyKernel3..."
    # Create module directories if they don't exist
    mkdir -p "$module_dest_dir_vendor"
    # Find and copy all built .ko files from the output directory
    # Adjust the find path if your 'O=out' structure differs
    find "$KERNEL_DIR/out" -name "*.ko" -exec cp -t "$module_dest_dir_vendor" {} +

    if [ -z "$(ls -A $module_dest_dir_vendor)" ]; then
       echo "- Warning: No kernel modules (.ko files) were found or copied."
       # Optionally remove the empty modules directory if nothing was copied
       rmdir "$module_dest_dir_vendor" 2>/dev/null || true
       rmdir "$ak3_dir/modules/vendor/lib" 2>/dev/null || true
       rmdir "$ak3_dir/modules/vendor" 2>/dev/null || true
       rmdir "$ak3_dir/modules" 2>/dev/null || true
    else
       echo "- Modules copied to $module_dest_dir_vendor"
       # Add commands here to setup module loading if needed by AnyKernel3 (e.g., creating module lists)
       # Example: find "$module_dest_dir_vendor" -type f -name '*.ko' -exec basename {} \; > "$module_dest_dir_vendor/modules.load"
    fi


    echo "- Creating zip file..."
    cd "$ak3_dir" || exit 1
    # Zip into the PARENT_DIR/files directory for easy upload by the workflow
    local output_zip_path="$PARENT_DIR/files/${ZIP_NAME}.zip"
    rm -f "$output_zip_path" # Remove old zip if it exists
    # Create new zip, excluding git files and other unnecessary items
    zip -r9 "$output_zip_path" . -x '*.git*' '*patch*' '*ramdisk*' 'README.md' || exit 1
    cd "$KERNEL_DIR" || exit 1
    echo "- Zip created: $output_zip_path"
}

# --- Main Build Process ---
echo "Starting Building ..."

# 1. Check device and set config
devicecheck

# 2. Toolchain PATH setup is handled by the GitHub Action workflow

# 3. Clean previous build output (optional but recommended)
echo "- Cleaning previous build..."
make $MAKE_PARAMS mrproper || echo "Clean failed, continuing..." # Don't exit if clean fails

# 4. Apply defconfig
echo "- Applying defconfig: $DEFCONFIG"
make $MAKE_PARAMS $DEFCONFIG || { echo "- Defconfig failed!"; exit 1; }

# 5. Build the kernel image AND modules
echo "- Building kernel ($MAKE_PARAMS)..."
# Build image first, then modules
make $MAKE_PARAMS || { echo "- Kernel image build failed!"; exit 1; }
echo "- Building modules ($MAKE_PARAMS)..."
make $MAKE_PARAMS modules || { echo "- Kernel modules build failed!"; exit 1; }


# 6. Prepare AnyKernel3
anykernel3

# 7. Create flashable zip (which now includes module copying)
makezipfile

echo "- Build finished successfully!"
exit 0