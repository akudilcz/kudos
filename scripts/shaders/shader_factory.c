/* kudos shader factory harness.
 *
 * Creates a Vulkan device on NVK (running GPU-less under Mesa's nouveau
 * drm-shim) and feeds each .spv through vkCreateShadersEXT. The patched
 * nvk_shader_upload (patches/0001) dumps the final SM89 upload image
 * (.sph + .bin + .meta.json) into NVK_SHADER_DUMP_DIR, named by
 * NVK_SHADER_DUMP_NAME which this harness sets per shader.
 *
 * Usage: shader_factory <name>.<vert|frag>.spv ...
 * Env (set by build.sh): LD_PRELOAD=libnouveau_noop_drm_shim.so
 *   NOUVEAU_CHIPSET=192 VK_ICD_FILENAMES=<nvk icd json>
 *   NVK_SHADER_DUMP_DIR=<output dir>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CHECK(expr)                                                     \
   do {                                                                 \
      VkResult r_ = (expr);                                             \
      if (r_ != VK_SUCCESS) {                                           \
         fprintf(stderr, "FATAL: %s = %d\n", #expr, r_);                \
         exit(1);                                                       \
      }                                                                 \
   } while (0)

static void *read_file(const char *path, size_t *size_out) {
   FILE *f = fopen(path, "rb");
   if (f == NULL) {
      fprintf(stderr, "FATAL: cannot open %s\n", path);
      exit(1);
   }
   fseek(f, 0, SEEK_END);
   long sz = ftell(f);
   fseek(f, 0, SEEK_SET);
   void *buf = malloc(sz);
   if (fread(buf, 1, sz, f) != (size_t)sz) {
      fprintf(stderr, "FATAL: short read on %s\n", path);
      exit(1);
   }
   fclose(f);
   *size_out = sz;
   return buf;
}

int main(int argc, char **argv) {
   if (argc < 2) {
      fprintf(stderr, "usage: %s <name>.<vert|frag>.spv ...\n", argv[0]);
      return 1;
   }

   VkApplicationInfo app = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "kudos-shader-factory",
      .apiVersion = VK_API_VERSION_1_3,
   };
   VkInstanceCreateInfo ici = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &app,
   };
   VkInstance inst;
   CHECK(vkCreateInstance(&ici, NULL, &inst));

   uint32_t npd = 1;
   VkPhysicalDevice pd;
   VkResult enum_r = vkEnumeratePhysicalDevices(inst, &npd, &pd);
   if ((enum_r != VK_SUCCESS && enum_r != VK_INCOMPLETE) || npd == 0) {
      fprintf(stderr, "FATAL: no NVK physical device (shim not loaded?)\n");
      return 1;
   }
   VkPhysicalDeviceProperties props;
   vkGetPhysicalDeviceProperties(pd, &props);
   fprintf(stderr, "factory: device = %s\n", props.deviceName);

   /* one graphics-capable queue family */
   uint32_t nqf = 0;
   vkGetPhysicalDeviceQueueFamilyProperties(pd, &nqf, NULL);
   VkQueueFamilyProperties qf[8];
   if (nqf > 8) nqf = 8;
   vkGetPhysicalDeviceQueueFamilyProperties(pd, &nqf, qf);
   uint32_t qfi = UINT32_MAX;
   for (uint32_t i = 0; i < nqf; i++) {
      if (qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
         qfi = i;
         break;
      }
   }
   if (qfi == UINT32_MAX) {
      fprintf(stderr, "FATAL: no graphics queue family\n");
      return 1;
   }

   VkPhysicalDeviceShaderObjectFeaturesEXT so_feat = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
      .shaderObject = VK_TRUE,
   };
   float prio = 1.0f;
   VkDeviceQueueCreateInfo qci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = qfi,
      .queueCount = 1,
      .pQueuePriorities = &prio,
   };
   const char *dev_exts[] = { "VK_EXT_shader_object" };
   VkDeviceCreateInfo dci = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .pNext = &so_feat,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &qci,
      .enabledExtensionCount = 1,
      .ppEnabledExtensionNames = dev_exts,
   };
   VkDevice dev;
   CHECK(vkCreateDevice(pd, &dci, NULL, &dev));

   PFN_vkCreateShadersEXT createShaders =
      (PFN_vkCreateShadersEXT)vkGetDeviceProcAddr(dev, "vkCreateShadersEXT");
   PFN_vkDestroyShaderEXT destroyShader =
      (PFN_vkDestroyShaderEXT)vkGetDeviceProcAddr(dev, "vkDestroyShaderEXT");
   if (createShaders == NULL || destroyShader == NULL) {
      fprintf(stderr, "FATAL: VK_EXT_shader_object entry points missing\n");
      return 1;
   }

   /* set 0, binding 0/1 = the two texture units (sampler2D), binding 2 = the ES 1.1
    * fixed-function state block. The bindings are generated into gles_state.glsl by
    * scripts/gl/es11_glsl_layout.py, and kudos mirrors this set when it binds.
    *
    * The state block is a UNIFORM BUFFER and not push constants: it is 1376 bytes and
    * NVK's maxPushConstantsSize is 256. Both stages read it — the vertex stage lights,
    * the fragment stage runs the texture environment and the fog.
    *
    * The 256-byte push range below belongs to the older fixed shaders (v_fullscreen,
    * f_resolve_msaa8 and friends) which still read pc_layout.glsl. */
   VkDescriptorSetLayoutBinding bindings[6] = {
      { .binding = 0,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT },
      { .binding = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT },
      { .binding = 2,
        .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT },
      /* bindings 3-5: the extra glTF material maps (GL_KUDOS_material_maps,
       * spec RND-005) sampled by f_pbr — normal, occlusion, emissive (the
       * metal-rough map rides binding 1, the second unit's slot). Appended
       * AFTER the original three so every existing blob's descriptor offsets
       * are untouched — a regeneration with unchanged sources must stay
       * byte-identical. */
      { .binding = 3,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT },
      { .binding = 4,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT },
      { .binding = 5,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT },
   };
   VkDescriptorSetLayoutCreateInfo dsli = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      .bindingCount = 6,
      .pBindings = bindings,
   };
   VkDescriptorSetLayout dsl;
   CHECK(vkCreateDescriptorSetLayout(dev, &dsli, NULL, &dsl));

   VkPushConstantRange pcr = {
      .stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
      .offset = 0,
      .size = 256,
   };

   for (int i = 1; i < argc; i++) {
      const char *path = argv[i];
      const char *base = strrchr(path, '/');
      base = base ? base + 1 : path;

      VkShaderStageFlagBits stage;
      VkShaderStageFlags next_stage;
      char name[256];
      const char *dot;
      if ((dot = strstr(base, ".vert.spv")) != NULL) {
         stage = VK_SHADER_STAGE_VERTEX_BIT;
         next_stage = VK_SHADER_STAGE_FRAGMENT_BIT;
      } else if ((dot = strstr(base, ".frag.spv")) != NULL) {
         stage = VK_SHADER_STAGE_FRAGMENT_BIT;
         next_stage = 0;
      } else {
         fprintf(stderr, "FATAL: %s is not <name>.<vert|frag>.spv\n", base);
         return 1;
      }
      snprintf(name, sizeof(name), "%.*s", (int)(dot - base), base);
      setenv("NVK_SHADER_DUMP_NAME", name, 1);

      size_t spv_size;
      void *spv = read_file(path, &spv_size);
      VkShaderCreateInfoEXT sci = {
         .sType = VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
         .stage = stage,
         .nextStage = next_stage,
         .codeType = VK_SHADER_CODE_TYPE_SPIRV_EXT,
         .codeSize = spv_size,
         .pCode = spv,
         .pName = "main",
         .setLayoutCount = 1,
         .pSetLayouts = &dsl,
         .pushConstantRangeCount = 1,
         .pPushConstantRanges = &pcr,
      };
      VkShaderEXT shader;
      VkResult r = createShaders(dev, 1, &sci, NULL, &shader);
      if (r != VK_SUCCESS) {
         fprintf(stderr, "FATAL: vkCreateShadersEXT(%s) = %d\n", name, r);
         return 1;
      }
      fprintf(stderr, "factory: compiled + dumped %s\n", name);
      destroyShader(dev, shader, NULL);
      free(spv);
   }

   vkDestroyDescriptorSetLayout(dev, dsl, NULL);
   vkDestroyDevice(dev, NULL);
   vkDestroyInstance(inst, NULL);
   return 0;
}
