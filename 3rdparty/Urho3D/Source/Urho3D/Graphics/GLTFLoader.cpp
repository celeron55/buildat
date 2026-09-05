//
// Copyright (c) 2008-2017 the Urho3D project.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
// Runtime glTF 2.0 loader. Parse path follows rbfx Utility/GLTFImporter
// (tinygltf, X-mirror RH→LH, joint-order skeleton). Fills 1.7.1 Model/Animation.
// simplified: morph targets and CUBICSPLINE tangents are ignored; add if a model needs them.
//

#include "../Precompiled.h"

#include "../Graphics/GLTFLoader.h"

#include "../Container/HashMap.h"
#include "../Container/Sort.h"
#include "../Container/Swap.h"
#include "../Core/Context.h"
#include "../Graphics/Animation.h"
#include "../Graphics/Geometry.h"
#include "../Graphics/IndexBuffer.h"
#include "../Graphics/Model.h"
#include "../Graphics/VertexBuffer.h"
#include "../IO/Deserializer.h"
#include "../IO/FileSystem.h"
#include "../IO/Log.h"
#include "../Math/Matrix3x4.h"
#include "../Math/Matrix4.h"

#include <cstring>

#ifdef __GNUC__
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-parameter"
#pragma GCC diagnostic ignored "-Wtype-limits"
#endif
#define TINYGLTF_IMPLEMENTATION
#define TINYGLTF_NO_STB_IMAGE
#define TINYGLTF_NO_STB_IMAGE_WRITE
#define TINYGLTF_NO_EXTERNAL_IMAGE
#define TINYGLTF_NOEXCEPTION
#define JSON_NOEXCEPTION
#include <tiny_gltf.h>
#ifdef __GNUC__
#pragma GCC diagnostic pop
#endif

#include "../DebugNew.h"

namespace Urho3D
{

namespace tg = tinygltf;

namespace
{

Vector3 MirrorX(const Vector3& v)
{
    return Vector3(-v.x_, v.y_, v.z_);
}

Quaternion MirrorX(const Quaternion& q)
{
    return Quaternion(q.w_, q.x_, -q.y_, -q.z_);
}

Matrix3x4 MirrorX(Matrix3x4 m)
{
    m.m01_ = -m.m01_;
    m.m10_ = -m.m10_;
    m.m02_ = -m.m02_;
    m.m20_ = -m.m20_;
    m.m03_ = -m.m03_;
    return m;
}

Quaternion RotationFromGltf(float x, float y, float z, float w)
{
    return Quaternion(w, x, y, z);
}

Matrix3x4 Mat4FromGltfColumnMajor(const float* m)
{
    Matrix4 u(
        m[0], m[4], m[8],  m[12],
        m[1], m[5], m[9],  m[13],
        m[2], m[6], m[10], m[14],
        m[3], m[7], m[11], m[15]);
    return Matrix3x4(u);
}

bool ReadFileBytes(Deserializer& source, PODVector<unsigned char>& bytes)
{
    unsigned start = source.GetPosition();
    unsigned size = source.GetSize() - start;
    if (!size)
        return false;
    bytes.Resize(size);
    return source.Read(&bytes[0], size) == size;
}

bool ParseTinyGLTF(Deserializer& source, tg::Model& model)
{
    PODVector<unsigned char> bytes;
    if (!ReadFileBytes(source, bytes))
        return false;

    tg::TinyGLTF loader;
    std::string err;
    std::string warn;
    String baseDir = GetPath(source.GetName());
    bool ok = false;
    if (bytes.Size() >= 4 && bytes[0] == 'g' && bytes[1] == 'l' && bytes[2] == 'T' && bytes[3] == 'F')
        ok = loader.LoadBinaryFromMemory(&model, &err, &warn, &bytes[0], bytes.Size(), baseDir.CString());
    else
        ok = loader.LoadASCIIFromString(&model, &err, &warn, (const char*)&bytes[0], bytes.Size(), baseDir.CString());

    if (!warn.empty())
        URHO3D_LOGWARNING(String(warn.c_str()));
    if (!ok)
    {
        URHO3D_LOGERROR(source.GetName() + " glTF load failed: " + String(err.c_str()));
        return false;
    }
    return true;
}

float ComponentAsFloat(const unsigned char* src, int componentType, bool normalized)
{
    switch (componentType)
    {
    case TINYGLTF_COMPONENT_TYPE_BYTE:
        {
            float v = (float)(*(const signed char*)src);
            return normalized ? Max(-1.0f, v / 127.0f) : v;
        }
    case TINYGLTF_COMPONENT_TYPE_UNSIGNED_BYTE:
        {
            float v = (float)(*src);
            return normalized ? v / 255.0f : v;
        }
    case TINYGLTF_COMPONENT_TYPE_SHORT:
        {
            float v = (float)(*(const short*)src);
            return normalized ? Max(-1.0f, v / 32767.0f) : v;
        }
    case TINYGLTF_COMPONENT_TYPE_UNSIGNED_SHORT:
        {
            float v = (float)(*(const unsigned short*)src);
            return normalized ? v / 65535.0f : v;
        }
    case TINYGLTF_COMPONENT_TYPE_INT:
        return (float)(*(const int*)src);
    case TINYGLTF_COMPONENT_TYPE_UNSIGNED_INT:
        return (float)(*(const unsigned*)src);
    case TINYGLTF_COMPONENT_TYPE_FLOAT:
        return *(const float*)src;
    case TINYGLTF_COMPONENT_TYPE_DOUBLE:
        return (float)(*(const double*)src);
    default:
        return 0.0f;
    }
}

unsigned ComponentAsUInt(const unsigned char* src, int componentType)
{
    switch (componentType)
    {
    case TINYGLTF_COMPONENT_TYPE_BYTE:
        return (unsigned)(*(const signed char*)src);
    case TINYGLTF_COMPONENT_TYPE_UNSIGNED_BYTE:
        return *src;
    case TINYGLTF_COMPONENT_TYPE_SHORT:
        return (unsigned)(*(const short*)src);
    case TINYGLTF_COMPONENT_TYPE_UNSIGNED_SHORT:
        return *(const unsigned short*)src;
    case TINYGLTF_COMPONENT_TYPE_INT:
        return (unsigned)(*(const int*)src);
    case TINYGLTF_COMPONENT_TYPE_UNSIGNED_INT:
        return *(const unsigned*)src;
    case TINYGLTF_COMPONENT_TYPE_FLOAT:
        return (unsigned)(*(const float*)src);
    default:
        return 0;
    }
}

bool ReadBufferView(const tg::Model& model, int bufferViewIndex, size_t byteOffset, int componentType, int type,
    int count, bool normalized, bool asUint, PODVector<float>* floats, PODVector<unsigned>* uints)
{
    if (bufferViewIndex < 0 || bufferViewIndex >= (int)model.bufferViews.size())
        return false;
    const tg::BufferView& view = model.bufferViews[bufferViewIndex];
    if (view.buffer < 0 || view.buffer >= (int)model.buffers.size())
        return false;
    const tg::Buffer& buffer = model.buffers[view.buffer];
    int comps = tg::GetNumComponentsInType((uint32_t)type);
    int compSize = tg::GetComponentSizeInBytes((uint32_t)componentType);
    if (comps <= 0 || compSize <= 0)
        return false;
    int stride = view.byteStride ? (int)view.byteStride : comps * compSize;
    size_t start = view.byteOffset + byteOffset;
    if (count <= 0)
    {
        if (asUint)
            uints->Clear();
        else
            floats->Clear();
        return true;
    }
    if (start + (size_t)((count - 1) * stride + comps * compSize) > buffer.data.size())
        return false;

    unsigned total = (unsigned)(count * comps);
    if (asUint)
        uints->Resize(total);
    else
        floats->Resize(total);

    const unsigned char* base = buffer.data.data() + start;
    for (int i = 0; i < count; ++i)
    {
        const unsigned char* row = base + i * stride;
        for (int c = 0; c < comps; ++c)
        {
            const unsigned char* src = row + c * compSize;
            unsigned dst = (unsigned)(i * comps + c);
            if (asUint)
                (*uints)[dst] = ComponentAsUInt(src, componentType);
            else
                (*floats)[dst] = ComponentAsFloat(src, componentType, normalized);
        }
    }
    return true;
}

bool ReadAccessorFloats(const tg::Model& model, int accessorIndex, PODVector<float>& out, int* outCount = 0, int* outComps = 0)
{
    if (accessorIndex < 0 || accessorIndex >= (int)model.accessors.size())
        return false;
    const tg::Accessor& acc = model.accessors[accessorIndex];
    int comps = tg::GetNumComponentsInType((uint32_t)acc.type);
    if (comps <= 0)
        return false;
    if (outCount)
        *outCount = (int)acc.count;
    if (outComps)
        *outComps = comps;

    if (acc.bufferView >= 0)
    {
        if (!ReadBufferView(model, acc.bufferView, acc.byteOffset, acc.componentType, acc.type, (int)acc.count,
                acc.normalized, false, &out, 0))
            return false;
    }
    else
        out.Resize((unsigned)(acc.count * comps));

    if (acc.sparse.isSparse && acc.sparse.count > 0)
    {
        PODVector<unsigned> indices;
        PODVector<float> values;
        if (!ReadBufferView(model, acc.sparse.indices.bufferView, acc.sparse.indices.byteOffset,
                acc.sparse.indices.componentType, TINYGLTF_TYPE_SCALAR, acc.sparse.count, false, true, 0, &indices))
            return false;
        if (!ReadBufferView(model, acc.sparse.values.bufferView, acc.sparse.values.byteOffset, acc.componentType,
                acc.type, acc.sparse.count, acc.normalized, false, &values, 0))
            return false;
        for (unsigned i = 0; i < indices.Size(); ++i)
        {
            unsigned dst = indices[i] * comps;
            for (int c = 0; c < comps; ++c)
                out[dst + c] = values[i * comps + c];
        }
    }
    return true;
}

bool ReadAccessorUInts(const tg::Model& model, int accessorIndex, PODVector<unsigned>& out)
{
    if (accessorIndex < 0 || accessorIndex >= (int)model.accessors.size())
        return false;
    const tg::Accessor& acc = model.accessors[accessorIndex];
    int comps = tg::GetNumComponentsInType((uint32_t)acc.type);
    if (comps <= 0)
        return false;
    if (acc.bufferView >= 0)
        return ReadBufferView(model, acc.bufferView, acc.byteOffset, acc.componentType, acc.type, (int)acc.count,
            false, true, 0, &out);
    out.Resize((unsigned)(acc.count * comps));
    return true;
}

bool ReadVec3s(const tg::Model& model, int accessorIndex, Vector<Vector3>& out)
{
    PODVector<float> f;
    int count = 0, comps = 0;
    if (!ReadAccessorFloats(model, accessorIndex, f, &count, &comps) || comps < 3)
        return false;
    out.Resize((unsigned)count);
    for (int i = 0; i < count; ++i)
        out[i] = Vector3(f[i * comps], f[i * comps + 1], f[i * comps + 2]);
    return true;
}

bool ReadVec2s(const tg::Model& model, int accessorIndex, Vector<Vector2>& out)
{
    PODVector<float> f;
    int count = 0, comps = 0;
    if (!ReadAccessorFloats(model, accessorIndex, f, &count, &comps) || comps < 2)
        return false;
    out.Resize((unsigned)count);
    for (int i = 0; i < count; ++i)
        out[i] = Vector2(f[i * comps], f[i * comps + 1]);
    return true;
}

bool ReadVec4s(const tg::Model& model, int accessorIndex, Vector<Vector4>& out)
{
    PODVector<float> f;
    int count = 0, comps = 0;
    if (!ReadAccessorFloats(model, accessorIndex, f, &count, &comps) || comps < 4)
        return false;
    out.Resize((unsigned)count);
    for (int i = 0; i < count; ++i)
        out[i] = Vector4(f[i * comps], f[i * comps + 1], f[i * comps + 2], f[i * comps + 3]);
    return true;
}

bool ReadQuaternions(const tg::Model& model, int accessorIndex, Vector<Quaternion>& out)
{
    Vector<Vector4> v;
    if (!ReadVec4s(model, accessorIndex, v))
        return false;
    out.Resize(v.Size());
    for (unsigned i = 0; i < v.Size(); ++i)
        out[i] = RotationFromGltf(v[i].x_, v[i].y_, v[i].z_, v[i].w_);
    return true;
}

bool ReadFloats(const tg::Model& model, int accessorIndex, Vector<float>& out)
{
    PODVector<float> f;
    int count = 0, comps = 0;
    if (!ReadAccessorFloats(model, accessorIndex, f, &count, &comps))
        return false;
    out.Resize((unsigned)count);
    for (int i = 0; i < count; ++i)
        out[i] = f[i * comps];
    return true;
}

void GetNodeLocalTRS(const tg::Node& node, Vector3& pos, Quaternion& rot, Vector3& scale)
{
    pos = Vector3::ZERO;
    rot = Quaternion::IDENTITY;
    scale = Vector3::ONE;
    if (!node.matrix.empty())
    {
        float m[16];
        for (unsigned i = 0; i < 16 && i < node.matrix.size(); ++i)
            m[i] = (float)node.matrix[i];
        Matrix3x4 tm = Mat4FromGltfColumnMajor(m);
        tm.Decompose(pos, rot, scale);
    }
    else
    {
        if (node.translation.size() >= 3)
            pos = Vector3((float)node.translation[0], (float)node.translation[1], (float)node.translation[2]);
        if (node.rotation.size() >= 4)
            rot = RotationFromGltf((float)node.rotation[0], (float)node.rotation[1], (float)node.rotation[2],
                (float)node.rotation[3]);
        if (node.scale.size() >= 3)
            scale = Vector3((float)node.scale[0], (float)node.scale[1], (float)node.scale[2]);
    }
    pos = MirrorX(pos);
    rot = MirrorX(rot);
}

String NodeName(const tg::Model& model, int index)
{
    if (index < 0 || index >= (int)model.nodes.size())
        return "Bone";
    const tg::Node& node = model.nodes[index];
    if (!node.name.empty())
        return String(node.name.c_str());
    return "Node_" + String(index);
}

void BuildParentMap(const tg::Model& model, PODVector<int>& parent)
{
    parent.Resize((unsigned)model.nodes.size());
    for (unsigned i = 0; i < parent.Size(); ++i)
        parent[i] = -1;
    for (unsigned i = 0; i < model.nodes.size(); ++i)
    {
        const tg::Node& node = model.nodes[i];
        for (size_t c = 0; c < node.children.size(); ++c)
        {
            int child = node.children[c];
            if (child >= 0 && child < (int)parent.Size())
                parent[child] = (int)i;
        }
    }
}

bool BuildSkeleton(const tg::Model& model, int skinIndex, Skeleton& skeleton, HashMap<int, unsigned>& nodeToBone)
{
    skeleton.ClearBones();
    nodeToBone.Clear();
    if (skinIndex < 0 || skinIndex >= (int)model.skins.size())
        return true;

    const tg::Skin& skin = model.skins[skinIndex];
    if (skin.joints.empty())
        return true;

    PODVector<int> parent;
    BuildParentMap(model, parent);

    Vector<Bone>& bones = skeleton.GetModifiableBones();
    for (size_t i = 0; i < skin.joints.size(); ++i)
    {
        int nodeIndex = skin.joints[i];
        nodeToBone[nodeIndex] = (unsigned)i;
        Bone bone;
        bone.name_ = NodeName(model, nodeIndex);
        bone.nameHash_ = bone.name_;
        bone.parentIndex_ = (unsigned)i;
        if (nodeIndex >= 0 && nodeIndex < (int)model.nodes.size())
            GetNodeLocalTRS(model.nodes[nodeIndex], bone.initialPosition_, bone.initialRotation_, bone.initialScale_);
        bones.Push(bone);
    }

    // Ancestors that are not joints (Armature root for the spider).
    for (size_t i = 0; i < skin.joints.size(); ++i)
    {
        int node = skin.joints[i];
        while (true)
        {
            int p = (node >= 0 && node < (int)parent.Size()) ? parent[node] : -1;
            if (p < 0 || nodeToBone.Contains(p))
                break;
            unsigned idx = bones.Size();
            nodeToBone[p] = idx;
            Bone bone;
            bone.name_ = NodeName(model, p);
            bone.nameHash_ = bone.name_;
            bone.parentIndex_ = idx;
            GetNodeLocalTRS(model.nodes[p], bone.initialPosition_, bone.initialRotation_, bone.initialScale_);
            bones.Push(bone);
            node = p;
        }
    }

    unsigned rootIndex = 0;
    bool foundRoot = false;
    for (HashMap<int, unsigned>::ConstIterator i = nodeToBone.Begin(); i != nodeToBone.End(); ++i)
    {
        int node = i->first_;
        unsigned boneIndex = i->second_;
        int p = (node >= 0 && node < (int)parent.Size()) ? parent[node] : -1;
        HashMap<int, unsigned>::ConstIterator pi = p >= 0 ? nodeToBone.Find(p) : nodeToBone.End();
        if (pi != nodeToBone.End())
            bones[boneIndex].parentIndex_ = pi->second_;
        else
        {
            bones[boneIndex].parentIndex_ = boneIndex;
            if (!foundRoot)
            {
                rootIndex = boneIndex;
                foundRoot = true;
            }
        }
    }
    skeleton.SetRootBoneIndex(foundRoot ? rootIndex : 0);

    if (skin.inverseBindMatrices >= 0)
    {
        PODVector<float> f;
        int count = 0, comps = 0;
        if (ReadAccessorFloats(model, skin.inverseBindMatrices, f, &count, &comps) && comps == 16)
        {
            unsigned n = Min((unsigned)count, (unsigned)skin.joints.size());
            for (unsigned i = 0; i < n; ++i)
                bones[i].offsetMatrix_ = MirrorX(Mat4FromGltfColumnMajor(&f[i * 16]));
        }
    }
    return true;
}

void UniqueSorted(Vector<float>& times)
{
    if (times.Size() < 2)
        return;
    Sort(times.Begin(), times.End());
    unsigned n = 1;
    for (unsigned i = 1; i < times.Size(); ++i)
    {
        if (times[i] - times[n - 1] > 1e-6f)
            times[n++] = times[i];
    }
    times.Resize(n);
}

template <class T>
void SampleAt(const Vector<float>& times, const Vector<T>& values, float t, bool step, T& out, const T& fallback)
{
    if (times.Empty() || values.Empty())
    {
        out = fallback;
        return;
    }
    unsigned n = Min(times.Size(), values.Size());
    if (t <= times[0] || n == 1)
    {
        out = values[0];
        return;
    }
    if (t >= times[n - 1])
    {
        out = values[n - 1];
        return;
    }
    unsigned i = 0;
    while (i + 1 < n && times[i + 1] < t)
        ++i;
    if (step)
    {
        out = values[i];
        return;
    }
    float d = times[i + 1] - times[i];
    float f = d > 0.0f ? (t - times[i]) / d : 0.0f;
    out = values[i].Lerp(values[i + 1], f);
}

void SampleQuatAt(const Vector<float>& times, const Vector<Quaternion>& values, float t, bool step, Quaternion& out)
{
    if (times.Empty() || values.Empty())
    {
        out = Quaternion::IDENTITY;
        return;
    }
    unsigned n = Min(times.Size(), values.Size());
    if (t <= times[0] || n == 1)
    {
        out = values[0];
        return;
    }
    if (t >= times[n - 1])
    {
        out = values[n - 1];
        return;
    }
    unsigned i = 0;
    while (i + 1 < n && times[i + 1] < t)
        ++i;
    if (step)
    {
        out = values[i];
        return;
    }
    float d = times[i + 1] - times[i];
    float f = d > 0.0f ? (t - times[i]) / d : 0.0f;
    out = values[i].Slerp(values[i + 1], f);
}

unsigned AttrCount(const tg::Model& model, const tg::Primitive& prim)
{
    if (prim.attributes.empty())
        return 0;
    int acc = prim.attributes.begin()->second;
    if (acc < 0 || acc >= (int)model.accessors.size())
        return 0;
    return (unsigned)model.accessors[acc].count;
}

PrimitiveType GltfPrimitiveType(int mode)
{
    switch (mode)
    {
    case TINYGLTF_MODE_POINTS:
        return POINT_LIST;
    case TINYGLTF_MODE_LINE:
        return LINE_LIST;
    case TINYGLTF_MODE_LINE_LOOP:
    case TINYGLTF_MODE_LINE_STRIP:
        return LINE_STRIP;
    case TINYGLTF_MODE_TRIANGLE_STRIP:
        return TRIANGLE_STRIP;
    case TINYGLTF_MODE_TRIANGLE_FAN:
        return TRIANGLE_FAN;
    case TINYGLTF_MODE_TRIANGLES:
    default:
        return TRIANGLE_LIST;
    }
}

}

bool LoadGLTFModel(Model* model, Deserializer& source)
{
    tg::Model gltf;
    if (!ParseTinyGLTF(source, gltf))
        return false;
    if (gltf.meshes.empty())
    {
        URHO3D_LOGERROR(source.GetName() + " glTF has no meshes");
        return false;
    }

    Context* context = model->GetContext();
    int skinIndex = -1;
    for (size_t i = 0; i < gltf.nodes.size(); ++i)
    {
        if (gltf.nodes[i].skin >= 0)
        {
            skinIndex = gltf.nodes[i].skin;
            break;
        }
    }
    if (skinIndex < 0 && !gltf.skins.empty())
        skinIndex = 0;

    Skeleton skeleton;
    HashMap<int, unsigned> nodeToBone;
    BuildSkeleton(gltf, skinIndex, skeleton, nodeToBone);
    bool skinned = skeleton.GetNumBones() > 0;

    model->geometries_.Clear();
    model->geometryBoneMappings_.Clear();
    model->geometryCenters_.Clear();
    model->morphs_.Clear();
    model->vertexBuffers_.Clear();
    model->indexBuffers_.Clear();
    model->morphRangeStarts_.Clear();
    model->morphRangeCounts_.Clear();
    model->loadVBData_.Clear();
    model->loadIBData_.Clear();
    model->loadGeometries_.Clear();

    BoundingBox box;
    bool boxInit = false;
    unsigned memoryUse = sizeof(Model);

    for (size_t meshIndex = 0; meshIndex < gltf.meshes.size(); ++meshIndex)
    {
        const tg::Mesh& mesh = gltf.meshes[meshIndex];
        for (size_t primIndex = 0; primIndex < mesh.primitives.size(); ++primIndex)
        {
            const tg::Primitive& prim = mesh.primitives[primIndex];
            unsigned vertexCount = AttrCount(gltf, prim);
            if (!vertexCount)
                continue;

            Vector<Vector3> positions;
            Vector<Vector3> normals;
            Vector<Vector2> uvs;
            Vector<Vector4> joints;
            Vector<Vector4> weights;
            std::map<std::string, int>::const_iterator it;

            it = prim.attributes.find("POSITION");
            if (it == prim.attributes.end() || !ReadVec3s(gltf, it->second, positions))
            {
                URHO3D_LOGERROR("glTF primitive missing POSITION");
                return false;
            }
            vertexCount = positions.Size();
            for (unsigned i = 0; i < positions.Size(); ++i)
                positions[i] = MirrorX(positions[i]);

            it = prim.attributes.find("NORMAL");
            if (it != prim.attributes.end() && ReadVec3s(gltf, it->second, normals))
            {
                for (unsigned i = 0; i < normals.Size(); ++i)
                    normals[i] = MirrorX(normals[i]).Normalized();
            }

            it = prim.attributes.find("TEXCOORD_0");
            if (it != prim.attributes.end())
                ReadVec2s(gltf, it->second, uvs);

            it = prim.attributes.find("JOINTS_0");
            if (it != prim.attributes.end())
            {
                PODVector<unsigned> ji;
                if (ReadAccessorUInts(gltf, it->second, ji) && ji.Size() >= vertexCount * 4)
                {
                    joints.Resize(vertexCount);
                    for (unsigned i = 0; i < vertexCount; ++i)
                        joints[i] = Vector4((float)ji[i * 4], (float)ji[i * 4 + 1], (float)ji[i * 4 + 2], (float)ji[i * 4 + 3]);
                }
            }
            it = prim.attributes.find("WEIGHTS_0");
            if (it != prim.attributes.end())
                ReadVec4s(gltf, it->second, weights);

            bool primSkinned = skinned && joints.Size() == vertexCount && weights.Size() == vertexCount;

            PODVector<VertexElement> elements;
            elements.Push(VertexElement(TYPE_VECTOR3, SEM_POSITION));
            if (normals.Size() == vertexCount)
                elements.Push(VertexElement(TYPE_VECTOR3, SEM_NORMAL));
            if (uvs.Size() == vertexCount)
                elements.Push(VertexElement(TYPE_VECTOR2, SEM_TEXCOORD));
            if (primSkinned)
            {
                elements.Push(VertexElement(TYPE_VECTOR4, SEM_BLENDWEIGHTS));
                elements.Push(VertexElement(TYPE_UBYTE4, SEM_BLENDINDICES));
            }

            unsigned vertexSize = VertexBuffer::GetVertexSize(elements);
            VertexBufferDesc vbDesc;
            vbDesc.vertexCount_ = vertexCount;
            vbDesc.vertexElements_ = elements;
            vbDesc.dataSize_ = vertexCount * vertexSize;
            vbDesc.data_ = SharedArrayPtr<unsigned char>(new unsigned char[vbDesc.dataSize_]);
            memset(vbDesc.data_.Get(), 0, vbDesc.dataSize_);

            Vector3 center = Vector3::ZERO;
            for (unsigned v = 0; v < vertexCount; ++v)
            {
                unsigned char* dest = vbDesc.data_.Get() + v * vertexSize;
                unsigned offset = 0;
                for (unsigned e = 0; e < elements.Size(); ++e)
                {
                    const VertexElement& el = elements[e];
                    if (el.semantic_ == SEM_POSITION)
                    {
                        memcpy(dest + offset, &positions[v], sizeof(Vector3));
                        center += positions[v];
                        if (!boxInit)
                        {
                            box.Define(positions[v]);
                            boxInit = true;
                        }
                        else
                            box.Merge(positions[v]);
                    }
                    else if (el.semantic_ == SEM_NORMAL)
                        memcpy(dest + offset, &normals[v], sizeof(Vector3));
                    else if (el.semantic_ == SEM_TEXCOORD)
                        memcpy(dest + offset, &uvs[v], sizeof(Vector2));
                    else if (el.semantic_ == SEM_BLENDWEIGHTS)
                    {
                        Vector4 w = weights[v];
                        float sum = w.x_ + w.y_ + w.z_ + w.w_;
                        if (sum > 0.0f)
                            w /= sum;
                        memcpy(dest + offset, &w, sizeof(Vector4));
                    }
                    else if (el.semantic_ == SEM_BLENDINDICES)
                    {
                        unsigned char idx[4];
                        const Vector4& jv = joints[v];
                        unsigned numBones = skeleton.GetNumBones();
                        idx[0] = (unsigned char)Min((unsigned)jv.x_, numBones ? numBones - 1 : 0);
                        idx[1] = (unsigned char)Min((unsigned)jv.y_, numBones ? numBones - 1 : 0);
                        idx[2] = (unsigned char)Min((unsigned)jv.z_, numBones ? numBones - 1 : 0);
                        idx[3] = (unsigned char)Min((unsigned)jv.w_, numBones ? numBones - 1 : 0);
                        memcpy(dest + offset, idx, 4);
                    }
                    offset += ELEMENT_TYPESIZES[el.type_];
                }
            }
            if (vertexCount)
                center /= (float)vertexCount;

            PODVector<unsigned> indices;
            if (prim.indices >= 0)
            {
                if (!ReadAccessorUInts(gltf, prim.indices, indices))
                    return false;
            }
            else
            {
                indices.Resize(vertexCount);
                for (unsigned i = 0; i < vertexCount; ++i)
                    indices[i] = i;
            }

            int mode = prim.mode < 0 ? TINYGLTF_MODE_TRIANGLES : prim.mode;
            PrimitiveType ptype = GltfPrimitiveType(mode);
            if (ptype == TRIANGLE_LIST)
            {
                for (unsigned i = 0; i + 2 < indices.Size(); i += 3)
                    Swap(indices[i], indices[i + 1]);
            }
            if (mode == TINYGLTF_MODE_LINE_LOOP && indices.Size())
                indices.Push(indices[0]);

            bool large = vertexCount > 65535;
            unsigned indexSize = large ? 4 : 2;
            IndexBufferDesc ibDesc;
            ibDesc.indexCount_ = indices.Size();
            ibDesc.indexSize_ = indexSize;
            ibDesc.dataSize_ = indices.Size() * indexSize;
            ibDesc.data_ = SharedArrayPtr<unsigned char>(new unsigned char[ibDesc.dataSize_]);
            if (large)
            {
                unsigned* dest = (unsigned*)ibDesc.data_.Get();
                for (unsigned i = 0; i < indices.Size(); ++i)
                    dest[i] = indices[i];
            }
            else
            {
                unsigned short* dest = (unsigned short*)ibDesc.data_.Get();
                for (unsigned i = 0; i < indices.Size(); ++i)
                    dest[i] = (unsigned short)indices[i];
            }

            unsigned vbRef = model->vertexBuffers_.Size();
            unsigned ibRef = model->indexBuffers_.Size();
            SharedPtr<VertexBuffer> vb(new VertexBuffer(context));
            SharedPtr<IndexBuffer> ib(new IndexBuffer(context));
            model->vertexBuffers_.Push(vb);
            model->indexBuffers_.Push(ib);
            model->loadVBData_.Push(vbDesc);
            model->loadIBData_.Push(ibDesc);
            model->morphRangeStarts_.Push(0);
            model->morphRangeCounts_.Push(0);

            SharedPtr<Geometry> geometry(new Geometry(context));
            Vector<SharedPtr<Geometry> > lods;
            lods.Push(geometry);
            model->geometries_.Push(lods);
            model->geometryCenters_.Push(center);
            model->geometryBoneMappings_.Push(PODVector<unsigned>());

            GeometryDesc gdesc;
            gdesc.type_ = ptype;
            gdesc.vbRef_ = vbRef;
            gdesc.ibRef_ = ibRef;
            gdesc.indexStart_ = 0;
            gdesc.indexCount_ = indices.Size();
            PODVector<GeometryDesc> lodDescs;
            lodDescs.Push(gdesc);
            model->loadGeometries_.Push(lodDescs);

            memoryUse += sizeof(VertexBuffer) + vbDesc.dataSize_ + sizeof(IndexBuffer) + ibDesc.dataSize_ + sizeof(Geometry);
        }
    }

    if (model->geometries_.Empty())
    {
        URHO3D_LOGERROR(source.GetName() + " glTF produced no geometry");
        return false;
    }

    model->skeleton_.Define(skeleton);
    model->boundingBox_ = boxInit ? box : BoundingBox(-Vector3::ONE, Vector3::ONE);
    memoryUse += skeleton.GetNumBones() * sizeof(Bone);
    model->SetMemoryUse(memoryUse);
    return true;
}

bool LoadGLTFAnimation(Animation* animation, Deserializer& source)
{
    tg::Model gltf;
    if (!ParseTinyGLTF(source, gltf))
        return false;
    if (gltf.animations.empty())
    {
        URHO3D_LOGERROR(source.GetName() + " glTF has no animations");
        return false;
    }

    const tg::Animation& src = gltf.animations[0];
    int skinIndex = -1;
    for (size_t i = 0; i < gltf.nodes.size(); ++i)
    {
        if (gltf.nodes[i].skin >= 0)
        {
            skinIndex = gltf.nodes[i].skin;
            break;
        }
    }
    if (skinIndex < 0 && !gltf.skins.empty())
        skinIndex = 0;

    Skeleton skeleton;
    HashMap<int, unsigned> nodeToBone;
    BuildSkeleton(gltf, skinIndex, skeleton, nodeToBone);

    struct BoneKeys
    {
        unsigned char mask;
        bool stepPos, stepRot, stepScale;
        Vector<float> posTimes, rotTimes, scaleTimes;
        Vector<Vector3> pos;
        Vector<Quaternion> rot;
        Vector<Vector3> scale;
        BoneKeys() : mask(0), stepPos(false), stepRot(false), stepScale(false) {}
    };
    HashMap<StringHash, BoneKeys> tracks;
    HashMap<StringHash, String> trackNames;

    for (size_t c = 0; c < src.channels.size(); ++c)
    {
        const tg::AnimationChannel& channel = src.channels[c];
        if (channel.sampler < 0 || channel.sampler >= (int)src.samplers.size())
            continue;
        if (channel.target_node < 0)
            continue;
        const tg::AnimationSampler& sampler = src.samplers[channel.sampler];
        Vector<float> times;
        if (!ReadFloats(gltf, sampler.input, times) || times.Empty())
            continue;

        String name = NodeName(gltf, channel.target_node);
        HashMap<int, unsigned>::ConstIterator boneIt = nodeToBone.Find(channel.target_node);
        if (boneIt != nodeToBone.End())
            name = skeleton.GetModifiableBones()[boneIt->second_].name_;

        bool step = sampler.interpolation == "STEP";
        BoneKeys& keys = tracks[StringHash(name)];
        trackNames[StringHash(name)] = name;

        if (channel.target_path == "translation")
        {
            Vector<Vector3> values;
            if (!ReadVec3s(gltf, sampler.output, values))
                continue;
            if (values.Size() == times.Size() * 3)
            {
                Vector<Vector3> centre;
                centre.Resize(times.Size());
                for (unsigned i = 0; i < times.Size(); ++i)
                    centre[i] = values[i * 3 + 1];
                values = centre;
            }
            for (unsigned i = 0; i < values.Size(); ++i)
                values[i] = MirrorX(values[i]);
            keys.posTimes = times;
            keys.pos = values;
            keys.stepPos = step;
            keys.mask |= CHANNEL_POSITION;
        }
        else if (channel.target_path == "rotation")
        {
            Vector<Quaternion> values;
            if (!ReadQuaternions(gltf, sampler.output, values))
                continue;
            if (values.Size() == times.Size() * 3)
            {
                Vector<Quaternion> centre;
                centre.Resize(times.Size());
                for (unsigned i = 0; i < times.Size(); ++i)
                    centre[i] = values[i * 3 + 1];
                values = centre;
            }
            for (unsigned i = 0; i < values.Size(); ++i)
                values[i] = MirrorX(values[i]);
            keys.rotTimes = times;
            keys.rot = values;
            keys.stepRot = step;
            keys.mask |= CHANNEL_ROTATION;
        }
        else if (channel.target_path == "scale")
        {
            Vector<Vector3> values;
            if (!ReadVec3s(gltf, sampler.output, values))
                continue;
            if (values.Size() == times.Size() * 3)
            {
                Vector<Vector3> centre;
                centre.Resize(times.Size());
                for (unsigned i = 0; i < times.Size(); ++i)
                    centre[i] = values[i * 3 + 1];
                values = centre;
            }
            keys.scaleTimes = times;
            keys.scale = values;
            keys.stepScale = step;
            keys.mask |= CHANNEL_SCALE;
        }
    }

    animation->RemoveAllTracks();
    animation->RemoveAllTriggers();
    String animName = src.name.empty() ? GetFileName(source.GetName()) : String(src.name.c_str());
    animation->SetAnimationName(animName);

    float length = 0.0f;
    unsigned memoryUse = sizeof(Animation);
    for (HashMap<StringHash, BoneKeys>::ConstIterator i = tracks.Begin(); i != tracks.End(); ++i)
    {
        const BoneKeys& keys = i->second_;
        HashMap<StringHash, String>::ConstIterator ni = trackNames.Find(i->first_);
        if (ni == trackNames.End())
            continue;
        AnimationTrack* track = animation->CreateTrack(ni->second_);
        track->channelMask_ = keys.mask;

        Vector<float> times;
        times.Insert(times.End(), keys.posTimes);
        times.Insert(times.End(), keys.rotTimes);
        times.Insert(times.End(), keys.scaleTimes);
        UniqueSorted(times);
        if (times.Empty())
            continue;

        Vector3 restPos = Vector3::ZERO;
        Quaternion restRot = Quaternion::IDENTITY;
        Vector3 restScale = Vector3::ONE;
        for (HashMap<int, unsigned>::ConstIterator b = nodeToBone.Begin(); b != nodeToBone.End(); ++b)
        {
            if (skeleton.GetModifiableBones()[b->second_].nameHash_ == i->first_)
            {
                const Bone& bone = skeleton.GetModifiableBones()[b->second_];
                restPos = bone.initialPosition_;
                restRot = bone.initialRotation_;
                restScale = bone.initialScale_;
                break;
            }
        }

        track->keyFrames_.Resize(times.Size());
        for (unsigned k = 0; k < times.Size(); ++k)
        {
            AnimationKeyFrame& kf = track->keyFrames_[k];
            kf.time_ = times[k];
            SampleAt(keys.posTimes, keys.pos, times[k], keys.stepPos, kf.position_, restPos);
            SampleQuatAt(keys.rotTimes, keys.rot, times[k], keys.stepRot, kf.rotation_);
            if (!(keys.mask & CHANNEL_ROTATION))
                kf.rotation_ = restRot;
            SampleAt(keys.scaleTimes, keys.scale, times[k], keys.stepScale, kf.scale_, restScale);
            if (kf.time_ > length)
                length = kf.time_;
        }
        memoryUse += sizeof(AnimationTrack) + times.Size() * sizeof(AnimationKeyFrame);
    }

    if (length <= 0.0f)
        length = 1.0f;
    animation->SetLength(length);
    animation->SetMemoryUse(memoryUse);
    return animation->GetNumTracks() > 0;
}

}
